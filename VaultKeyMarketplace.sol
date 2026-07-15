// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title VaultKeyMarketplace
 * @notice Trustless, atomic marketplace for VaultKey trading with tiered fees
 * @dev Enables sellers to list VaultKeys for sale and buyers to purchase atomically.
 *      Revenue model: taker fee on each sale (paid by buyer, additional to price).
 *      Supports both on-chain listings and gasless EIP-712 signed listings.
 *
 * Fee system:
 * - 5 tiers (0-4) with decreasing taker fees to incentivize volume
 * - Tier 0 is the default for all users (highest fee)
 * - Admin (feeRecipient) manually assigns tiers based on user activity
 * - Both buyer AND seller tiers are considered: the BETTER (lower fee) tier applies
 * - Fee is additive: buyer pays price + fee. Fee goes to feeRecipient wallet
 * - Tier assignment is designed for future migration to off-chain indexing (subgraph)
 *
 * Design decisions:
 * - Catalog-style (not order book) — each listing is unique, no matching engine
 * - Seller retains custody of VaultKeys until purchase (approval-based, not escrow)
 * - EIP-712 signatures allow gasless listing creation (buyer submits signature + payment)
 * - Listings can be for full or partial VaultKey amounts
 * - Seller can update price or cancel at any time
 * - Listings auto-invalidate if seller lacks balance or allowance
 *
 * Security:
 * - ReentrancyGuard on all state-changing buyer operations
 * - No escrow = no stuck funds risk
 * - Nonce-based replay protection for EIP-712 listings
 * - Checks-effects-interactions pattern throughout
 * - MAX_TAKER_FEE cap prevents abusive fee configuration
 */
contract VaultKeyMarketplace is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Maximum taker fee: 5% (500 basis points)
    uint256 public constant MAX_TAKER_FEE = 500;

    /// @notice Number of available tiers
    uint256 public constant TIER_COUNT = 5;

    /// @notice EIP-712 typehash for gasless listings
    bytes32 public constant LISTING_TYPEHASH = keccak256(
        "Listing(address seller,address vaultKeyAddress,uint256 vaultKeyAmount,address paymentToken,uint256 pricePerVK,uint256 nonce,uint256 deadline)"
    );

    // ============ Structs ============

    struct Listing {
        address seller;           // Owner of VaultKeys being sold
        address vaultKeyAddress;  // VaultKey token address
        uint256 vaultKeyAmount;   // Amount of VaultKeys for sale (18 decimals)
        address paymentToken;     // Token accepted as payment (e.g., USDC, WETH)
        uint256 pricePerVK;       // Price per 1 whole VaultKey (1e18 units) in paymentToken
        bool active;              // Whether listing is active
        uint256 createdAt;        // Block timestamp when listed
    }

    /// @notice Fee tier configuration
    /// @dev takerFeeBps is in basis points (e.g., 250 = 2.5%)
    struct Tier {
        uint256 takerFeeBps;      // Taker fee in basis points
        bool active;              // Whether this tier is configured
    }

    /// @notice Parameters for gasless purchase (avoids stack-too-deep)
    struct GaslessOrder {
        address seller;
        address vaultKeyAddress;
        uint256 vaultKeyAmount;
        address paymentToken;
        uint256 pricePerVK;
        uint256 nonce;
        uint256 deadline;
    }

    // ============ State Variables ============

    /// @notice All listings by ID
    mapping(uint256 => Listing) public listings;

    /// @notice Listing counter
    uint256 public listingCounter;

    /// @notice Address that receives marketplace fees and controls settings
    address public feeRecipient;

    /// @notice Fee tier configurations (index 0-4)
    Tier[5] public tiers;

    /// @notice User tier assignments (address => tier index)
    /// @dev Default is 0 (highest fee tier). Admin sets higher tiers as reward.
    mapping(address => uint256) public userTier;

    /// @notice Nonces for EIP-712 replay protection (seller => nonce)
    mapping(address => uint256) public nonces;

    /// @notice Track used signature hashes to prevent replay
    mapping(bytes32 => bool) public usedSignatures;

    // ============ Events ============

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address vaultKeyAddress,
        uint256 vaultKeyAmount,
        address paymentToken,
        uint256 pricePerVK
    );

    event ListingUpdated(
        uint256 indexed listingId,
        uint256 newPricePerVK,
        uint256 newVaultKeyAmount
    );

    event ListingCancelled(uint256 indexed listingId);

    event Purchase(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 vaultKeyAmount,
        uint256 totalPrice,
        uint256 feeAmount,
        uint256 tierApplied
    );

    event GaslessPurchase(
        address indexed buyer,
        address indexed seller,
        address vaultKeyAddress,
        uint256 vaultKeyAmount,
        uint256 totalPrice,
        uint256 feeAmount,
        uint256 tierApplied
    );

    event TierUpdated(uint256 indexed tierIndex, uint256 takerFeeBps, bool active);
    event UserTierUpdated(address indexed user, uint256 oldTier, uint256 newTier);
    event BatchUserTierUpdated(uint256 usersUpdated, uint256 newTier);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error ZeroPrice();
    error FeeTooHigh();
    error OnlyFeeRecipient();
    error OnlySeller();
    error ListingNotActive();
    error InsufficientListingBalance();
    error ExceedsListedAmount();
    error InvalidSignature();
    error SignatureExpired();
    error SignatureAlreadyUsed();
    error BuyerIsSeller();
    error InvalidPaymentToken();
    error InvalidTier();
    error TierNotActive();
    error BatchTooLarge();

    // ============ Constructor ============

    /**
     * @notice Deploys the marketplace with default tier configuration
     * @param _feeRecipient Address that receives fees and manages settings
     *
     * @dev Default tiers (can be changed by admin after deploy):
     *      Tier 0: 2.50% (default for all users)
     *      Tier 1: 2.00%
     *      Tier 2: 1.50%
     *      Tier 3: 1.00%
     *      Tier 4: 0.50% (VIP)
     */
    constructor(
        address _feeRecipient
    ) EIP712("VaultKeyMarketplace", "1") {
        if (_feeRecipient == address(0)) revert ZeroAddress();

        feeRecipient = _feeRecipient;

        // Initialize default tiers
        tiers[0] = Tier({ takerFeeBps: 250, active: true });  // 2.50% — default
        tiers[1] = Tier({ takerFeeBps: 200, active: true });  // 2.00%
        tiers[2] = Tier({ takerFeeBps: 150, active: true });  // 1.50%
        tiers[3] = Tier({ takerFeeBps: 100, active: true });  // 1.00%
        tiers[4] = Tier({ takerFeeBps: 50,  active: true });  // 0.50% — VIP
    }

    // ============ Listing Management ============

    /**
     * @notice Creates an on-chain listing to sell VaultKeys
     * @param _vaultKeyAddress Address of the VaultKey ERC-20 token
     * @param _vaultKeyAmount Amount of VaultKeys to sell (18 decimals)
     * @param _paymentToken Token accepted as payment
     * @param _pricePerVK Price per 1 whole VaultKey (1e18) in paymentToken units
     * @return listingId The ID of the created listing
     *
     * @dev Seller must approve this contract for _vaultKeyAmount BEFORE calling.
     *      VaultKeys stay in seller's wallet until a buyer purchases (no escrow).
     */
    function createListing(
        address _vaultKeyAddress,
        uint256 _vaultKeyAmount,
        address _paymentToken,
        uint256 _pricePerVK
    ) external returns (uint256 listingId) {
        if (_vaultKeyAddress == address(0)) revert ZeroAddress();
        if (_paymentToken == address(0)) revert ZeroAddress();
        if (_vaultKeyAmount == 0) revert ZeroAmount();
        if (_pricePerVK == 0) revert ZeroPrice();

        listingId = listingCounter++;

        listings[listingId] = Listing({
            seller: msg.sender,
            vaultKeyAddress: _vaultKeyAddress,
            vaultKeyAmount: _vaultKeyAmount,
            paymentToken: _paymentToken,
            pricePerVK: _pricePerVK,
            active: true,
            createdAt: block.timestamp
        });

        emit ListingCreated(
            listingId,
            msg.sender,
            _vaultKeyAddress,
            _vaultKeyAmount,
            _paymentToken,
            _pricePerVK
        );
    }

    /**
     * @notice Updates an existing listing's price and/or amount
     * @param _listingId ID of the listing to update
     * @param _newPricePerVK New price per VaultKey (0 = keep current)
     * @param _newVaultKeyAmount New amount (0 = keep current)
     */
    function updateListing(
        uint256 _listingId,
        uint256 _newPricePerVK,
        uint256 _newVaultKeyAmount
    ) external {
        Listing storage listing = listings[_listingId];
        if (msg.sender != listing.seller) revert OnlySeller();
        if (!listing.active) revert ListingNotActive();

        if (_newPricePerVK > 0) {
            listing.pricePerVK = _newPricePerVK;
        }
        if (_newVaultKeyAmount > 0) {
            listing.vaultKeyAmount = _newVaultKeyAmount;
        }

        emit ListingUpdated(_listingId, listing.pricePerVK, listing.vaultKeyAmount);
    }

    /**
     * @notice Cancels a listing
     * @param _listingId ID of the listing to cancel
     */
    function cancelListing(uint256 _listingId) external {
        Listing storage listing = listings[_listingId];
        if (msg.sender != listing.seller) revert OnlySeller();
        if (!listing.active) revert ListingNotActive();

        listing.active = false;

        emit ListingCancelled(_listingId);
    }

    // ============ Purchase (On-Chain Listing) ============

    /**
     * @notice Purchases VaultKeys from an on-chain listing
     * @param _listingId ID of the listing
     * @param _vaultKeyAmount Amount of VaultKeys to buy (can be partial)
     *
     * @dev Atomic: payment + VaultKey transfer happen in one transaction.
     *      Fee is determined by the BETTER tier between buyer and seller.
     *      Buyer pays: (vkAmount * pricePerVK / 1e18) + taker fee.
     *      Buyer must approve paymentToken for totalPrice + fee BEFORE calling.
     *      Seller must have approved VaultKeys to this contract.
     */
    function purchase(
        uint256 _listingId,
        uint256 _vaultKeyAmount
    ) external nonReentrant {
        Listing storage listing = listings[_listingId];

        // Validations
        if (!listing.active) revert ListingNotActive();
        if (_vaultKeyAmount == 0) revert ZeroAmount();
        if (_vaultKeyAmount > listing.vaultKeyAmount) revert ExceedsListedAmount();
        if (msg.sender == listing.seller) revert BuyerIsSeller();

        // Determine applicable fee (best tier between buyer and seller)
        uint256 appliedTier = _getBestTier(msg.sender, listing.seller);
        uint256 feeBps = tiers[appliedTier].takerFeeBps;

        // Calculate amounts
        uint256 totalPrice = (_vaultKeyAmount * listing.pricePerVK) / 1e18;
        uint256 feeAmount = (totalPrice * feeBps) / 10000;

        // Update listing state (effects before interactions)
        listing.vaultKeyAmount -= _vaultKeyAmount;
        if (listing.vaultKeyAmount == 0) {
            listing.active = false;
        }

        // Verify seller still has the VaultKeys
        IERC20 vaultKeyToken = IERC20(listing.vaultKeyAddress);
        if (vaultKeyToken.balanceOf(listing.seller) < _vaultKeyAmount) {
            revert InsufficientListingBalance();
        }

        // Transfer payment: buyer -> seller
        IERC20 paymentToken = IERC20(listing.paymentToken);
        paymentToken.safeTransferFrom(msg.sender, listing.seller, totalPrice);

        // Transfer fee: buyer -> feeRecipient
        if (feeAmount > 0) {
            paymentToken.safeTransferFrom(msg.sender, feeRecipient, feeAmount);
        }

        // Transfer VaultKeys: seller -> buyer
        vaultKeyToken.safeTransferFrom(listing.seller, msg.sender, _vaultKeyAmount);

        emit Purchase(
            _listingId,
            msg.sender,
            listing.seller,
            _vaultKeyAmount,
            totalPrice,
            feeAmount,
            appliedTier
        );
    }

    // ============ Gasless Purchase (EIP-712 Signature) ============

    /**
     * @notice Purchases VaultKeys using an off-chain EIP-712 signed listing
     * @param _order Struct containing all order parameters
     * @param _signature EIP-712 signature from seller
     *
     * @dev The seller signs a listing off-chain (zero gas). The buyer submits
     *      the signature + payment in a single transaction.
     *      Fee tier: best tier between buyer and seller applies.
     */
    function purchaseWithSignature(
        GaslessOrder calldata _order,
        bytes calldata _signature
    ) external nonReentrant {
        // Validate inputs
        if (_order.seller == address(0)) revert ZeroAddress();
        if (_order.vaultKeyAddress == address(0)) revert ZeroAddress();
        if (_order.paymentToken == address(0)) revert InvalidPaymentToken();
        if (_order.vaultKeyAmount == 0) revert ZeroAmount();
        if (_order.pricePerVK == 0) revert ZeroPrice();
        if (msg.sender == _order.seller) revert BuyerIsSeller();
        if (block.timestamp > _order.deadline) revert SignatureExpired();

        // Verify signature and nonce
        _verifySignature(_order, _signature);

        // Determine applicable fee (best tier between buyer and seller)
        uint256 appliedTier = _getBestTier(msg.sender, _order.seller);
        uint256 feeBps = tiers[appliedTier].takerFeeBps;

        // Calculate amounts
        uint256 totalPrice = (_order.vaultKeyAmount * _order.pricePerVK) / 1e18;
        uint256 feeAmount = (totalPrice * feeBps) / 10000;

        // Execute transfers
        _executeGaslessTransfers(
            _order.seller,
            _order.vaultKeyAddress,
            _order.vaultKeyAmount,
            _order.paymentToken,
            totalPrice,
            feeAmount
        );

        emit GaslessPurchase(
            msg.sender,
            _order.seller,
            _order.vaultKeyAddress,
            _order.vaultKeyAmount,
            totalPrice,
            feeAmount,
            appliedTier
        );
    }

    /**
     * @notice Increments sender's nonce to invalidate all pending signatures
     * @dev Use this to "cancel" all off-chain listings at once
     */
    function incrementNonce() external {
        nonces[msg.sender]++;
    }

    // ============ View Functions ============

    /**
     * @notice Returns full listing details
     */
    function getListing(uint256 _listingId) external view returns (Listing memory) {
        return listings[_listingId];
    }

    /**
     * @notice Returns all 5 tier configurations
     */
    function getAllTiers() external view returns (Tier[5] memory) {
        return tiers;
    }

    /**
     * @notice Returns the effective fee for a transaction between buyer and seller
     * @param _buyer Buyer address
     * @param _seller Seller address
     * @return tierIndex The tier that would apply
     * @return feeBps The fee in basis points
     */
    function getEffectiveFee(
        address _buyer,
        address _seller
    ) external view returns (uint256 tierIndex, uint256 feeBps) {
        tierIndex = _getBestTier(_buyer, _seller);
        feeBps = tiers[tierIndex].takerFeeBps;
    }

    /**
     * @notice Calculates total cost for a buyer considering tiers
     * @param _listingId Listing ID
     * @param _vaultKeyAmount Amount of VaultKeys to buy
     * @param _buyer Buyer address (to determine tier)
     * @return totalPrice Price paid to seller
     * @return feeAmount Fee paid to marketplace
     * @return totalCost Total amount buyer needs to approve (price + fee)
     * @return tierApplied Which tier was used
     */
    function calculatePurchaseCost(
        uint256 _listingId,
        uint256 _vaultKeyAmount,
        address _buyer
    ) external view returns (
        uint256 totalPrice,
        uint256 feeAmount,
        uint256 totalCost,
        uint256 tierApplied
    ) {
        Listing memory listing = listings[_listingId];
        tierApplied = _getBestTier(_buyer, listing.seller);
        uint256 feeBps = tiers[tierApplied].takerFeeBps;

        totalPrice = (_vaultKeyAmount * listing.pricePerVK) / 1e18;
        feeAmount = (totalPrice * feeBps) / 10000;
        totalCost = totalPrice + feeAmount;
    }

    /**
     * @notice Calculates total cost for a gasless purchase considering tiers
     * @param _vaultKeyAmount Amount of VaultKeys
     * @param _pricePerVK Price per VaultKey
     * @param _buyer Buyer address
     * @param _seller Seller address
     * @return totalPrice Price paid to seller
     * @return feeAmount Fee paid to marketplace
     * @return totalCost Total buyer cost
     * @return tierApplied Which tier was used
     */
    function calculateGaslessPurchaseCost(
        uint256 _vaultKeyAmount,
        uint256 _pricePerVK,
        address _buyer,
        address _seller
    ) external view returns (
        uint256 totalPrice,
        uint256 feeAmount,
        uint256 totalCost,
        uint256 tierApplied
    ) {
        tierApplied = _getBestTier(_buyer, _seller);
        uint256 feeBps = tiers[tierApplied].takerFeeBps;

        totalPrice = (_vaultKeyAmount * _pricePerVK) / 1e18;
        feeAmount = (totalPrice * feeBps) / 10000;
        totalCost = totalPrice + feeAmount;
    }

    /**
     * @notice Checks if a listing is effectively valid
     * @param _listingId Listing ID
     * @return valid True if listing can be purchased
     * @return availableAmount Actual purchasable amount
     */
    function isListingValid(uint256 _listingId) external view returns (
        bool valid,
        uint256 availableAmount
    ) {
        Listing memory listing = listings[_listingId];
        if (!listing.active) return (false, 0);

        IERC20 vaultKeyToken = IERC20(listing.vaultKeyAddress);
        uint256 sellerBalance = vaultKeyToken.balanceOf(listing.seller);
        uint256 sellerAllowance = vaultKeyToken.allowance(listing.seller, address(this));

        uint256 effectiveAmount = _min(listing.vaultKeyAmount, _min(sellerBalance, sellerAllowance));

        return (effectiveAmount > 0, effectiveAmount);
    }

    /**
     * @notice Returns the EIP-712 domain separator
     */
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Returns current nonce for a seller
     */
    function getNonce(address _seller) external view returns (uint256) {
        return nonces[_seller];
    }

    // ============ Admin: Tier Management ============

    /**
     * @notice Updates a tier's fee configuration
     * @param _tierIndex Tier index (0-4)
     * @param _takerFeeBps New taker fee in basis points
     * @param _active Whether the tier is active
     *
     * @dev Tier 0 cannot be deactivated (it's the default fallback).
     *      Higher tiers can be deactivated; users in deactivated tiers
     *      fall back to tier 0.
     */
    function setTier(
        uint256 _tierIndex,
        uint256 _takerFeeBps,
        bool _active
    ) external {
        if (msg.sender != feeRecipient) revert OnlyFeeRecipient();
        if (_tierIndex >= TIER_COUNT) revert InvalidTier();
        if (_takerFeeBps > MAX_TAKER_FEE) revert FeeTooHigh();
        // Tier 0 must always be active (default fallback)
        if (_tierIndex == 0 && !_active) revert InvalidTier();

        tiers[_tierIndex] = Tier({
            takerFeeBps: _takerFeeBps,
            active: _active
        });

        emit TierUpdated(_tierIndex, _takerFeeBps, _active);
    }

    /**
     * @notice Sets a single user's tier
     * @param _user User address
     * @param _tierIndex Tier to assign (0-4)
     */
    function setUserTier(address _user, uint256 _tierIndex) external {
        if (msg.sender != feeRecipient) revert OnlyFeeRecipient();
        if (_user == address(0)) revert ZeroAddress();
        if (_tierIndex >= TIER_COUNT) revert InvalidTier();
        if (!tiers[_tierIndex].active) revert TierNotActive();

        uint256 oldTier = userTier[_user];
        userTier[_user] = _tierIndex;

        emit UserTierUpdated(_user, oldTier, _tierIndex);
    }

    /**
     * @notice Sets tier for multiple users at once (batch update)
     * @param _users Array of user addresses
     * @param _tierIndex Tier to assign to all users
     *
     * @dev Max 200 users per batch to avoid block gas limit.
     *      For larger updates, call multiple times.
     */
    function batchSetUserTier(
        address[] calldata _users,
        uint256 _tierIndex
    ) external {
        if (msg.sender != feeRecipient) revert OnlyFeeRecipient();
        if (_tierIndex >= TIER_COUNT) revert InvalidTier();
        if (!tiers[_tierIndex].active) revert TierNotActive();
        if (_users.length > 200) revert BatchTooLarge();

        for (uint256 i = 0; i < _users.length; i++) {
            if (_users[i] != address(0)) {
                userTier[_users[i]] = _tierIndex;
            }
        }

        emit BatchUserTierUpdated(_users.length, _tierIndex);
    }

    // ============ Admin: Fee Recipient ============

    /**
     * @notice Transfers feeRecipient role
     * @param _newRecipient New fee recipient address
     */
    function updateFeeRecipient(address _newRecipient) external {
        if (msg.sender != feeRecipient) revert OnlyFeeRecipient();
        if (_newRecipient == address(0)) revert ZeroAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = _newRecipient;

        emit FeeRecipientUpdated(oldRecipient, _newRecipient);
    }

    // ============ Internal Helpers ============

    /**
     * @notice Verifies EIP-712 signature and nonce for gasless orders
     * @param _order The gasless order parameters
     * @param _signature The EIP-712 signature
     */
    function _verifySignature(
        GaslessOrder calldata _order,
        bytes calldata _signature
    ) internal {
        bytes32 structHash = keccak256(abi.encode(
            LISTING_TYPEHASH,
            _order.seller,
            _order.vaultKeyAddress,
            _order.vaultKeyAmount,
            _order.paymentToken,
            _order.pricePerVK,
            _order.nonce,
            _order.deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);

        // Prevent replay
        if (usedSignatures[digest]) revert SignatureAlreadyUsed();
        usedSignatures[digest] = true;

        // Verify signature
        address signer = ECDSA.recover(digest, _signature);
        if (signer != _order.seller) revert InvalidSignature();

        // Verify nonce
        if (_order.nonce != nonces[_order.seller]) revert InvalidSignature();
        nonces[_order.seller]++;
    }

    /**
     * @notice Executes the atomic transfers for a gasless purchase
     * @param _seller Seller address
     * @param _vaultKeyAddress VaultKey token address
     * @param _vaultKeyAmount Amount of VaultKeys
     * @param _paymentToken Payment token address
     * @param _totalPrice Price to pay seller
     * @param _feeAmount Fee to pay feeRecipient
     */
    function _executeGaslessTransfers(
        address _seller,
        address _vaultKeyAddress,
        uint256 _vaultKeyAmount,
        address _paymentToken,
        uint256 _totalPrice,
        uint256 _feeAmount
    ) internal {
        // Verify seller has VaultKeys
        IERC20 vaultKeyToken = IERC20(_vaultKeyAddress);
        if (vaultKeyToken.balanceOf(_seller) < _vaultKeyAmount) {
            revert InsufficientListingBalance();
        }

        // Transfer payment: buyer -> seller
        IERC20 paymentToken = IERC20(_paymentToken);
        paymentToken.safeTransferFrom(msg.sender, _seller, _totalPrice);

        // Transfer fee: buyer -> feeRecipient
        if (_feeAmount > 0) {
            paymentToken.safeTransferFrom(msg.sender, feeRecipient, _feeAmount);
        }

        // Transfer VaultKeys: seller -> buyer
        vaultKeyToken.safeTransferFrom(_seller, msg.sender, _vaultKeyAmount);
    }

    /**
     * @notice Determines the best (lowest fee) active tier between two users
     * @param _buyer Buyer address
     * @param _seller Seller address
     * @return bestTier The tier index with the lowest fee
     *
     * @dev Both participants benefit from either party's tier.
     *      This incentivizes high-volume users to trade with anyone,
     *      as their tier benefits the counterparty too.
     *      If a user's assigned tier is inactive, they fall back to tier 0.
     */
    function _getBestTier(
        address _buyer,
        address _seller
    ) internal view returns (uint256 bestTier) {
        uint256 buyerTier = userTier[_buyer];
        uint256 sellerTier = userTier[_seller];

        // Validate tiers are active, fallback to 0 if not
        if (!tiers[buyerTier].active) buyerTier = 0;
        if (!tiers[sellerTier].active) sellerTier = 0;

        // Return the tier with the LOWER fee
        // Compare actual fee values in case tiers are configured non-linearly
        if (tiers[buyerTier].takerFeeBps <= tiers[sellerTier].takerFeeBps) {
            return buyerTier;
        } else {
            return sellerTier;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
