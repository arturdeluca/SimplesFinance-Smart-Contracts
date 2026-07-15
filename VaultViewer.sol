// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SwapVaultFactory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title VaultViewer
 * @notice Helper contract for batch queries and enhanced vault information
 * @dev Read-only contract to reduce gas costs for frontends
 */
contract VaultViewer {
    SwapVaultFactory public immutable factory;
    
    struct VaultInfo {
        uint256 vaultId;
        address creator;
        address tokenDeposited;
        uint256 amountDeposited;
        address tokenRequired;
        uint256 amountRequired;
        uint256 expiration;
        address vaultKeyAddress;
        uint256 amountExercised;
        uint256 remainingAmount;
        bool finalized;
        bool isActive;
        bool isExpired;
        bool isEmergencyFinalizable;
        uint256 lockedTakerFee;
        uint256 lockedMakerFee;
        uint256 vaultKeyTotalSupply;
        string tokenDepositedSymbol;
        string tokenRequiredSymbol;
    }
    
    constructor(address _factory) {
        require(_factory != address(0), "Invalid factory");
        factory = SwapVaultFactory(_factory);
    }
    
    /**
     * @notice Gets detailed information about a vault
     * @param _vaultId ID of vault
     * @return VaultInfo struct with all vault details
     */
    function getVaultInfo(uint256 _vaultId) public view returns (VaultInfo memory) {
        SwapVaultFactory.Vault memory vault = factory.getVault(_vaultId);
        
        uint256 remainingAmount = vault.amountDeposited - vault.amountExercised;
        bool isActive = block.timestamp < vault.expiration && 
                       !vault.finalized && 
                       vault.amountExercised < vault.amountDeposited;
        bool isExpired = block.timestamp >= vault.expiration;
        bool isEmergencyFinalizable = !vault.finalized && 
                                      block.timestamp >= vault.expiration + factory.EMERGENCY_DELAY();
        
        // Get VaultKey total supply
        uint256 vaultKeySupply = IERC20(vault.vaultKeyAddress).totalSupply();
        
        // Try to get token symbols (may fail for non-standard tokens)
        string memory depositedSymbol = _getSymbol(vault.tokenDeposited);
        string memory requiredSymbol = _getSymbol(vault.tokenRequired);
        
        return VaultInfo({
            vaultId: _vaultId,
            creator: vault.creator,
            tokenDeposited: vault.tokenDeposited,
            amountDeposited: vault.amountDeposited,
            tokenRequired: vault.tokenRequired,
            amountRequired: vault.amountRequired,
            expiration: vault.expiration,
            vaultKeyAddress: vault.vaultKeyAddress,
            amountExercised: vault.amountExercised,
            remainingAmount: remainingAmount,
            finalized: vault.finalized,
            isActive: isActive,
            isExpired: isExpired,
            isEmergencyFinalizable: isEmergencyFinalizable,
            lockedTakerFee: vault.lockedTakerFee,
            lockedMakerFee: vault.lockedMakerFee,
            vaultKeyTotalSupply: vaultKeySupply,
            tokenDepositedSymbol: depositedSymbol,
            tokenRequiredSymbol: requiredSymbol
        });
    }
    
    /**
     * @notice Gets information for multiple vaults in one call
     * @param _vaultIds Array of vault IDs
     * @return Array of VaultInfo structs
     */
    function getMultipleVaults(uint256[] calldata _vaultIds) 
        external 
        view 
        returns (VaultInfo[] memory) 
    {
        VaultInfo[] memory vaultInfos = new VaultInfo[](_vaultIds.length);
        
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            vaultInfos[i] = getVaultInfo(_vaultIds[i]);
        }
        
        return vaultInfos;
    }
    
    /**
     * @notice Gets all active vaults (not expired, not fully exercised)
     * @param _startId Start vault ID
     * @param _count Number of vaults to check
     * @return Array of VaultInfo for active vaults
     */
    function getActiveVaults(uint256 _startId, uint256 _count) 
        external 
        view 
        returns (VaultInfo[] memory) 
    {
        uint256 vaultCounter = factory.vaultCounter();
        uint256 endId = _startId + _count;
        if (endId > vaultCounter) {
            endId = vaultCounter;
        }
        
        // First pass: count active vaults
        uint256 activeCount = 0;
        for (uint256 i = _startId; i < endId; i++) {
            if (factory.isVaultActive(i)) {
                activeCount++;
            }
        }
        
        // Second pass: populate array
        VaultInfo[] memory activeVaults = new VaultInfo[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = _startId; i < endId; i++) {
            if (factory.isVaultActive(i)) {
                activeVaults[index] = getVaultInfo(i);
                index++;
            }
        }
        
        return activeVaults;
    }
    
    /**
     * @notice Gets vaults created by a specific address
     * @param _creator Address of creator
     * @param _startId Start vault ID
     * @param _count Number of vaults to check
     * @return Array of VaultInfo for creator's vaults
     */
    function getVaultsByCreator(address _creator, uint256 _startId, uint256 _count) 
        external 
        view 
        returns (VaultInfo[] memory) 
    {
        uint256 vaultCounter = factory.vaultCounter();
        uint256 endId = _startId + _count;
        if (endId > vaultCounter) {
            endId = vaultCounter;
        }
        
        // First pass: count creator's vaults
        uint256 creatorVaultCount = 0;
        for (uint256 i = _startId; i < endId; i++) {
            SwapVaultFactory.Vault memory vault = factory.getVault(i);
            if (vault.creator == _creator) {
                creatorVaultCount++;
            }
        }
        
        // Second pass: populate array
        VaultInfo[] memory creatorVaults = new VaultInfo[](creatorVaultCount);
        uint256 index = 0;
        
        for (uint256 i = _startId; i < endId; i++) {
            SwapVaultFactory.Vault memory vault = factory.getVault(i);
            if (vault.creator == _creator) {
                creatorVaults[index] = getVaultInfo(i);
                index++;
            }
        }
        
        return creatorVaults;
    }
    
    /**
     * @notice Gets vaults by token pair
     * @param _tokenDeposited Token deposited in vault
     * @param _tokenRequired Token required to exercise
     * @param _startId Start vault ID
     * @param _count Number of vaults to check
     * @return Array of VaultInfo for matching vaults
     */
    function getVaultsByTokenPair(
        address _tokenDeposited,
        address _tokenRequired,
        uint256 _startId,
        uint256 _count
    ) external view returns (VaultInfo[] memory) {
        uint256 vaultCounter = factory.vaultCounter();
        uint256 endId = _startId + _count;
        if (endId > vaultCounter) {
            endId = vaultCounter;
        }
        
        // First pass: count matching vaults
        uint256 matchCount = 0;
        for (uint256 i = _startId; i < endId; i++) {
            SwapVaultFactory.Vault memory vault = factory.getVault(i);
            if (vault.tokenDeposited == _tokenDeposited && vault.tokenRequired == _tokenRequired) {
                matchCount++;
            }
        }
        
        // Second pass: populate array
        VaultInfo[] memory matchingVaults = new VaultInfo[](matchCount);
        uint256 index = 0;
        
        for (uint256 i = _startId; i < endId; i++) {
            SwapVaultFactory.Vault memory vault = factory.getVault(i);
            if (vault.tokenDeposited == _tokenDeposited && vault.tokenRequired == _tokenRequired) {
                matchingVaults[index] = getVaultInfo(i);
                index++;
            }
        }
        
        return matchingVaults;
    }
    
    /**
     * @notice Gets user's VaultKey balances for multiple vaults
     * @param _user Address of user
     * @param _vaultIds Array of vault IDs
     * @return Array of VaultKey balances
     */
    function getUserVaultKeyBalances(address _user, uint256[] calldata _vaultIds) 
        external 
        view 
        returns (uint256[] memory) 
    {
        uint256[] memory balances = new uint256[](_vaultIds.length);
        
        for (uint256 i = 0; i < _vaultIds.length; i++) {
            SwapVaultFactory.Vault memory vault = factory.getVault(_vaultIds[i]);
            balances[i] = IERC20(vault.vaultKeyAddress).balanceOf(_user);
        }
        
        return balances;
    }
    
    /**
     * @notice Calculates expected payoff for exercising a vault
     * @param _vaultId ID of vault
     * @param _vaultKeyAmount Amount of VaultKey to exercise
     * @return requiredAmount Amount of tokenRequired to pay
     * @return receivedAmount Amount of tokenDeposited to receive
     * @return feeAmount Protocol fee (using vault's locked fee)
     * @return totalCost Total cost = requiredAmount + feeAmount
     */
    function calculatePayoff(uint256 _vaultId, uint256 _vaultKeyAmount) 
        external 
        view 
        returns (
            uint256 requiredAmount,
            uint256 receivedAmount,
            uint256 feeAmount,
            uint256 totalCost
        ) 
    {
        uint256 takerFeeAmount;
        uint256 totalFromTaker;
        (requiredAmount, receivedAmount, takerFeeAmount, , totalFromTaker, ) = factory.calculateExerciseAmounts(
            _vaultId,
            _vaultKeyAmount
        );
        feeAmount = takerFeeAmount;
        totalCost = totalFromTaker;
        
        return (requiredAmount, receivedAmount, feeAmount, totalCost);
    }
    
    // ============ Helper Functions ============
    
    /**
     * @dev Safely gets token symbol
     */
    function _getSymbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "UNKNOWN";
        }
    }
}