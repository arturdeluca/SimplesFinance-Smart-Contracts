// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VaultKey
 * @notice ERC20 token representing rights to exercise a swap vault
 * @dev Minted when vault is created, burned when exercised
 * @dev Each vault always mints exactly 100 VaultKeys (with 18 decimals)
 * @dev 1 VK = 1% of the vault. Fractional VKs are supported.
 */
contract VaultKey is ERC20, Ownable {
    uint256 public immutable vaultId;
    address public immutable factory;
    
    /**
     * @notice Creates a new VaultKey token
     * @param name Token name (e.g., "VaultKey #123")
     * @param symbol Token symbol (e.g., "VK-123")
     * @param creator Address to receive initial supply
     * @param totalSupply Total supply to mint (always 100 * 1e18)
     * @param _vaultId ID of the associated vault
     */
    constructor(
        string memory name,
        string memory symbol,
        address creator,
        uint256 totalSupply,
        uint256 _vaultId
    ) ERC20(name, symbol) Ownable(creator) {
        require(creator != address(0), "Invalid creator");
        require(totalSupply > 0, "Invalid supply");
        
        factory = msg.sender;
        vaultId = _vaultId;
        
        _mint(creator, totalSupply);
    }
    
    /**
     * @notice Burns VaultKey tokens (only callable by factory during exercise)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external {
        require(msg.sender == factory, "Only factory can burn");
        _burn(from, amount);
    }
    
    /**
     * @notice Returns decimals (18 for fractional VK support)
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}