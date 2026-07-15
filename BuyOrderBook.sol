// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BuyOrderBook
 * @notice Trustless buy-side order book for VaultKey trading with escrow
 * @dev Enables buyers to post buy orders (bids) for specific VaultKeys.
 *      Buyer deposits payment into escrow. Sellers fill orders atomically.
 *      100% on-chain, no off-chain dependencies.
 *
 * Fee system:
 * - Launches with ZERO fees to incentivize adoption
 * - feeRecipient can enable fees later (maker/taker model)
 * - makerFeeBps: charged to the buyer (order creator) on fill
 * - takerFeeBps: charged to the seller (order filler) on fill
 * - Both capped at MAX_FEE (5%)
 * - Fees deducted from payment at fill time, sent to feeRecipient
 *
 * Flow:
 * 1. Buyer calls createBuyOrder() → deposits paymentToken into escrow
 * 2. Order is visible on-chain for sellers to discover
 * 3. Seller calls fillBuyOrder() → atomic swap: VKs to buyer, payment to seller
 * 4. Buyer can cancelBuyOrder() at any time → escrow returned in full
 * 5. Buyer can updateBuyOrder() to change price → escrow adjusted automatically
 *
 * Security:
 * - ReentrancyGuard on all state-changing operations
 * - Checks-effects-interactions pattern throughout
 * - SafeERC20 for all token transfers
 * - No approval-based model: funds held in escrow (no stale allowance risk)
 * - Fee-on-transfer tokens not supported (same as SwapVaultFactory)
 */
contract BuyOrderBook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Maximum fee: 5% (500 basis points)
    uint256 public constant MAX_FEE = 500;

    // ============ Structs ============

    struct BuyOrder {
        address buyer;            // Creator of the buy order
        address vaultKeyAddress;  // VaultKey token they want to buy
        uint256 vkAmount;         // Amount of VaultKeys wanted
        address paymentToken;     // Token used for payment (e.g., USDC, WETH)
        uint256 pricePerVK;       // Price offered per 1 whole VaultKey (1e18 units)
        uint256 escrowAmount;     // Total payment held in escrow (vkAmount * pricePerVK / 1e18)
        bool active;              // Whether order is still open
        uint256 createdAt;        // Block timestamp when created
    }

    // ============ State Variables ============

    /// @notice All buy orders by ID
    mapping(uint256 => BuyOrder) public buyOrders;

    /// @notice Order counter (next order ID)
    uint256 public orderCounter;

    /// @notice Address that receives fees and controls fee settings
    address public feeRecipient;

    /// @notice Fee charged to buyer (maker) in basis points — starts at 0
    uint256 public makerFeeBps;

    /// @notice Fee charged to seller (taker) in basis points — starts at 0
    uint256 public takerFeeBps;

    /// @notice Track active order count per vaultKey for frontend enumeration
    /// @dev Not used for logic, just a convenience counter
    mapping(address => uint256) public activeOrderCount;

    // ============ Events ============

    event BuyOrderCreated(
        uint256 indexed orderId,
        address indexed buyer,
        address vaultKeyAddress,
        uint256 vkAmount,
        address paymentToken,
        uint256 pricePerVK,
        uint256 escrowAmount
    );

    event BuyOrderFilled(
        uint256 indexed orderId,
        address indexed seller,
        address indexed buyer,
        uint256 vkAmountFilled,
        uint256 paymentToSeller,
        uint256 makerFee,
        uint256 takerFee
    );

    event BuyOrderCancelled(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 escrowReturned
    );

    event BuyOrderUpdated(
        uint256 indexed orderId,
        uint256 oldPricePerVK,
        uint256 newPricePerVK,
        uint256 oldEscrow,
        uint256 newEscrow
    );

    event FeesUpdated(uint256 makerFeeBps, uint256 takerFeeBps);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error ZeroPrice();
    error FeeTooHigh();
    error OnlyFeeRecipient();
    error OnlyBuyer();
    error OrderNotActive();
    error ExceedsOrderAmount();
    error SellerIsBuyer();
    error InsufficientSellerBalance();
    error FeeOnTransferNotSupported();
    error InsufficientEscrow();

    // ============ Constructor ============

    /**
     * @notice Deploys the BuyOrderBook with zero fees
     * @param _feeRecipient Address that controls fee settings and receives future fees
     *
     * @dev Fees start at 0/0. feeRecipient can enable them later via setFees().
     *      This allows a "free launch" to bootstrap liquidity, with the option
     *      to introduce maker/taker fees once the order book has traction.
     */
    constructor(address _feeRecipient) {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
        // makerFeeBps = 0 (default)
        // takerFeeBps = 0 (default)
    }

    // ============ Order Management ============

    /**
     * @notice Creates a buy order and deposits payment into escrow
     * @param _vaultKeyAddress Address of the VaultKey token to buy
     * @param _vkAmount Amount of VaultKeys wanted (18 decimals)
     * @param _paymentToken Token used for payment
     * @param _pricePerVK Price offered per 1 whole VaultKey (1e18 units)
     * @return orderId The ID of the created order
     *
     * @dev Buyer must approve paymentToken for escrowAmount BEFORE calling.
     *      escrowAmount = _vkAmount * _pricePerVK / 1e18
     *      Funds are transferred to this contract and held until fill or cancel.
     *      Fee-on-transfer tokens are explicitly rejected.
     */
    function createBuyOrder(
        address _vaultKeyAddress,
        uint256 _vkAmount,
        address _paymentToken,
        uint256 _pricePerVK
    ) external nonReentrant returns (uint256 orderId) {
        if (_vaultKeyAddress == address(0)) revert ZeroAddress();
        if (_paymentToken == address(0)) revert ZeroAddress();
        if (_vkAmount == 0) revert ZeroAmount();
        if (_pricePerVK == 0) revert ZeroPrice();

        uint256 escrowAmount = (_vkAmount * _pricePerVK) / 1e18;
        if (escrowAmount == 0) revert ZeroAmount();

        // Transfer payment to escrow (with fee-on-transfer check)
        IERC20 payment = IERC20(_paymentToken);
        uint256 balanceBefore = payment.balanceOf(address(this));
        payment.safeTransferFrom(msg.sender, address(this), escrowAmount);
        uint256 balanceAfter = payment.balanceOf(address(this));
        if (balanceAfter - balanceBefore != escrowAmount) revert FeeOnTransferNotSupported();

        orderId = orderCounter++;

        buyOrders[orderId] = BuyOrder({
            buyer: msg.sender,
            vaultKeyAddress: _vaultKeyAddress,
            vkAmount: _vkAmount,
            paymentToken: _paymentToken,
            pricePerVK: _pricePerVK,
            escrowAmount: escrowAmount,
            active: true,
            createdAt: block.timestamp
        });

        activeOrderCount[_vaultKeyAddress]++;

        emit BuyOrderCreated(
            orderId,
            msg.sender,
            _vaultKeyAddress,
            _vkAmount,
            _paymentToken,
            _pricePerVK,
            escrowAmount
        );
    }

    /**
     * @notice Fills a buy order (total or partial) — seller sends VaultKeys, receives payment
     * @param _orderId ID of the buy order to fill
     * @param _vkAmount Amount of VaultKeys to sell into this order
     *
     * @dev Atomic swap:
     *      1. VaultKeys transferred from seller to buyer
     *      2. Payment released from escrow to seller (minus taker fee)
     *      3. Maker fee deducted from escrow and sent to feeRecipient
     *      4. Taker fee deducted from seller's payment and sent to feeRecipient
     *
     *      Seller must approve VaultKeys to this contract BEFORE calling.
     *      Partial fills are supported — remaining escrow stays for future fills.
     */
    function fillBuyOrder(
        uint256 _orderId,
        uint256 _vkAmount
    ) external nonReentrant {
        BuyOrder storage order = buyOrders[_orderId];

        // Validations
        if (!order.active) revert OrderNotActive();
        if (_vkAmount == 0) revert ZeroAmount();
        if (_vkAmount > order.vkAmount) revert ExceedsOrderAmount();
        if (msg.sender == order.buyer) revert SellerIsBuyer();

        // Verify seller has VaultKeys
        IERC20 vaultKeyToken = IERC20(order.vaultKeyAddress);
        if (vaultKeyToken.balanceOf(msg.sender) < _vkAmount) revert InsufficientSellerBalance();

        // Calculate payment for this fill
        uint256 paymentForFill = (_vkAmount * order.pricePerVK) / 1e18;

        // Calculate fees
        uint256 makerFee = (paymentForFill * makerFeeBps) / 10000;
        uint256 takerFee = (paymentForFill * takerFeeBps) / 10000;
        uint256 paymentToSeller = paymentForFill - takerFee;
        uint256 escrowNeeded = paymentForFill + makerFee;

        // Guard: escrow must cover payment + maker fee
        // This can fail if makerFee was raised after order creation
        if (escrowNeeded > order.escrowAmount) revert InsufficientEscrow();

        // Effects — update state before interactions
        order.vkAmount -= _vkAmount;
        order.escrowAmount -= escrowNeeded;

        if (order.vkAmount == 0) {
            order.active = false;
            activeOrderCount[order.vaultKeyAddress]--;
        }

        // Interactions — transfers
        IERC20 payment = IERC20(order.paymentToken);

        // 1. VaultKeys: seller → buyer
        vaultKeyToken.safeTransferFrom(msg.sender, order.buyer, _vkAmount);

        // 2. Payment: escrow → seller (minus taker fee)
        payment.safeTransfer(msg.sender, paymentToSeller);

        // 3. Fees: escrow → feeRecipient
        uint256 totalFees = makerFee + takerFee;
        if (totalFees > 0) {
            payment.safeTransfer(feeRecipient, totalFees);
        }

        emit BuyOrderFilled(
            _orderId,
            msg.sender,
            order.buyer,
            _vkAmount,
            paymentToSeller,
            makerFee,
            takerFee
        );
    }

    /**
     * @notice Cancels a buy order and returns escrow to buyer
     * @param _orderId ID of the order to cancel
     *
     * @dev Only the buyer can cancel. Full remaining escrow is returned.
     *      Can cancel even partially filled orders (remaining escrow returned).
     */
    function cancelBuyOrder(uint256 _orderId) external nonReentrant {
        BuyOrder storage order = buyOrders[_orderId];

        if (msg.sender != order.buyer) revert OnlyBuyer();
        if (!order.active) revert OrderNotActive();

        uint256 escrowToReturn = order.escrowAmount;

        // Effects
        order.active = false;
        order.escrowAmount = 0;
        activeOrderCount[order.vaultKeyAddress]--;

        // Interactions — return escrow
        IERC20(order.paymentToken).safeTransfer(msg.sender, escrowToReturn);

        emit BuyOrderCancelled(_orderId, msg.sender, escrowToReturn);
    }

    /**
     * @notice Updates the price of an existing buy order, adjusting escrow
     * @param _orderId ID of the order to update
     * @param _newPricePerVK New price per VaultKey
     *
     * @dev If new price is higher: buyer must have approved the difference.
     *      If new price is lower: excess escrow is returned to buyer.
     *      The vkAmount stays the same — only price changes.
     *      Fee-on-transfer protection on additional deposits.
     */
    function updateBuyOrder(
        uint256 _orderId,
        uint256 _newPricePerVK
    ) external nonReentrant {
        BuyOrder storage order = buyOrders[_orderId];

        if (msg.sender != order.buyer) revert OnlyBuyer();
        if (!order.active) revert OrderNotActive();
        if (_newPricePerVK == 0) revert ZeroPrice();

        uint256 oldPricePerVK = order.pricePerVK;
        uint256 oldEscrow = order.escrowAmount;
        uint256 newEscrow = (order.vkAmount * _newPricePerVK) / 1e18;
        if (newEscrow == 0) revert ZeroAmount();

        // Effects — update price and escrow
        order.pricePerVK = _newPricePerVK;
        order.escrowAmount = newEscrow;

        // Interactions — adjust escrow
        if (newEscrow > oldEscrow) {
            // Price increased: pull additional funds from buyer
            uint256 additionalEscrow = newEscrow - oldEscrow;
            IERC20 payment = IERC20(order.paymentToken);

            uint256 balanceBefore = payment.balanceOf(address(this));
            payment.safeTransferFrom(msg.sender, address(this), additionalEscrow);
            uint256 balanceAfter = payment.balanceOf(address(this));
            if (balanceAfter - balanceBefore != additionalEscrow) revert FeeOnTransferNotSupported();
        } else if (newEscrow < oldEscrow) {
            // Price decreased: return excess to buyer
            uint256 excessEscrow = oldEscrow - newEscrow;
            IERC20(order.paymentToken).safeTransfer(msg.sender, excessEscrow);
        }
        // If newEscrow == oldEscrow: no transfer needed

        emit BuyOrderUpdated(
            _orderId,
            oldPricePerVK,
            _newPricePerVK,
            oldEscrow,
            newEscrow
        );
    }

    // ============ View Functions ============

    /**
     * @notice Returns full buy order details
     * @param _orderId ID of the order
     */
    function getBuyOrder(uint256 _orderId) external view returns (BuyOrder memory) {
        return buyOrders[_orderId];
    }

    /**
     * @notice Returns active buy orders for a specific VaultKey address
     * @param _vaultKeyAddress VaultKey token address to filter by
     * @param _startId Start scanning from this order ID
     * @param _count Maximum number of results to return
     * @return orders Array of matching active orders
     * @return orderIds Array of corresponding order IDs
     *
     * @dev Paginated scan. Frontend should call with increasing _startId.
     *      Gas-intensive for large datasets — intended for RPC calls, not on-chain use.
     */
    function getBuyOrdersForVault(
        address _vaultKeyAddress,
        uint256 _startId,
        uint256 _count
    ) external view returns (BuyOrder[] memory orders, uint256[] memory orderIds) {
        uint256 total = orderCounter;
        if (_startId >= total) {
            return (new BuyOrder[](0), new uint256[](0));
        }

        // First pass: count matching orders
        uint256 end = _startId + _count;
        if (end > total) end = total;

        uint256 matchCount = 0;
        for (uint256 i = _startId; i < end; i++) {
            if (buyOrders[i].active && buyOrders[i].vaultKeyAddress == _vaultKeyAddress) {
                matchCount++;
            }
        }

        // Second pass: collect results
        orders = new BuyOrder[](matchCount);
        orderIds = new uint256[](matchCount);
        uint256 idx = 0;

        for (uint256 i = _startId; i < end; i++) {
            if (buyOrders[i].active && buyOrders[i].vaultKeyAddress == _vaultKeyAddress) {
                orders[idx] = buyOrders[i];
                orderIds[idx] = i;
                idx++;
            }
        }
    }

    /**
     * @notice Returns active buy orders created by a specific buyer
     * @param _buyer Buyer address
     * @param _startId Start scanning from this order ID
     * @param _count Maximum number of results
     * @return orders Array of matching active orders
     * @return orderIds Array of corresponding order IDs
     */
    function getBuyOrdersByBuyer(
        address _buyer,
        uint256 _startId,
        uint256 _count
    ) external view returns (BuyOrder[] memory orders, uint256[] memory orderIds) {
        uint256 total = orderCounter;
        if (_startId >= total) {
            return (new BuyOrder[](0), new uint256[](0));
        }

        uint256 end = _startId + _count;
        if (end > total) end = total;

        uint256 matchCount = 0;
        for (uint256 i = _startId; i < end; i++) {
            if (buyOrders[i].active && buyOrders[i].buyer == _buyer) {
                matchCount++;
            }
        }

        orders = new BuyOrder[](matchCount);
        orderIds = new uint256[](matchCount);
        uint256 idx = 0;

        for (uint256 i = _startId; i < end; i++) {
            if (buyOrders[i].active && buyOrders[i].buyer == _buyer) {
                orders[idx] = buyOrders[i];
                orderIds[idx] = i;
                idx++;
            }
        }
    }

    /**
     * @notice Calculates what a seller would receive for filling an order
     * @param _orderId Order ID
     * @param _vkAmount Amount of VaultKeys to sell
     * @return grossPayment Total payment from escrow
     * @return takerFeeAmount Fee deducted from seller
     * @return makerFeeAmount Fee deducted from escrow (buyer's cost)
     * @return netToSeller Amount seller actually receives
     */
    function calculateFillAmounts(
        uint256 _orderId,
        uint256 _vkAmount
    ) external view returns (
        uint256 grossPayment,
        uint256 takerFeeAmount,
        uint256 makerFeeAmount,
        uint256 netToSeller
    ) {
        BuyOrder memory order = buyOrders[_orderId];
        grossPayment = (_vkAmount * order.pricePerVK) / 1e18;
        makerFeeAmount = (grossPayment * makerFeeBps) / 10000;
        takerFeeAmount = (grossPayment * takerFeeBps) / 10000;
        netToSeller = grossPayment - takerFeeAmount;
    }

    /**
     * @notice Returns current fee configuration
     * @return _makerFeeBps Buyer fee in basis points
     * @return _takerFeeBps Seller fee in basis points
     */
    function getFees() external view returns (uint256 _makerFeeBps, uint256 _takerFeeBps) {
        return (makerFeeBps, takerFeeBps);
    }

    // ============ Admin: Fee Management ============

    /**
     * @notice Updates maker and taker fees
     * @param _makerFeeBps New maker fee (buyer) in basis points
     * @param _takerFeeBps New taker fee (seller) in basis points
     *
     * @dev Both fees capped at MAX_FEE (5%).
     *      Set both to 0 to disable fees.
     *      Changes apply to future fills only — existing escrow is not affected.
     *      Note: when makerFee > 0, the escrow must cover price + makerFee.
     *      For simplicity in v1, makerFee is deducted from escrow at fill time.
     *      This means: if fees are raised AFTER order creation, existing orders
     *      may have insufficient escrow for the fee portion. Sellers should check
     *      calculateFillAmounts() before filling.
     */
    function setFees(
        uint256 _makerFeeBps,
        uint256 _takerFeeBps
    ) external {
        if (msg.sender != feeRecipient) revert OnlyFeeRecipient();
        if (_makerFeeBps > MAX_FEE) revert FeeTooHigh();
        if (_takerFeeBps > MAX_FEE) revert FeeTooHigh();

        makerFeeBps = _makerFeeBps;
        takerFeeBps = _takerFeeBps;

        emit FeesUpdated(_makerFeeBps, _takerFeeBps);
    }

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
}
