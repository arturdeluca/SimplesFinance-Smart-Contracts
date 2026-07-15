# Simples Protocol — SwapVault

A minimalist, decentralized options protocol on Arbitrum. Users create conditional swap contracts (vaults) peer-to-peer — no oracles, no liquidity pools, no automated pricing.

---

## Overview

The protocol lets any user deposit a token into a vault and define their own strike price. Buyers acquire **VaultKeys** (ERC-20 tokens representing the right to exercise the swap) and decide manually when to exercise. Settlement is on-chain; everything else — listing, pricing, discovery — happens in the frontend marketplace.

**Revenue model:** The protocol itself is free and public. The frontend marketplace is a business that charges taker and maker fees on exercise.

---

## Contracts

| Contract | Description |
|----------|-------------|
| `SwapVaultFactory.sol` | Core protocol. Creates vaults, manages exercise, finalization, and emergency recovery. |
| `VaultKey.sol` | ERC-20 token representing the right to exercise a vault. 100 VaultKeys per vault (fixed supply). |
| `VaultViewer.sol` | Read-only helper for batch queries and derived fields. |
| `VaultKeyMarketplace.sol` | Trustless marketplace for VaultKey trading. Approval-based (no escrow). EIP-712 gasless listings. |
| `BuyOrderBook.sol` | On-chain buy orders with escrow. Buyers deposit payment; sellers fill atomically. |

---

## Architecture

```
1. CREATE
   Alice approves tokenDeposited → calls createVault() → receives 100 VaultKeys

2. SELL (via marketplace)
   Alice lists VaultKeys → Bob buys them, paying premium to Alice

3. EXERCISE
   Bob approves (tokenRequired + takerFeeAmount) → calls exercise()
   → Contract receives totalFromTaker
   → Alice receives requiredAmount - makerFeeAmount
   → feeCollector receives takerFeeAmount + makerFeeAmount
   → Bob receives proportional tokenDeposited

4. EXPIRATION
   Vault expires → creator or VaultKey holder calls finalizeVault()
   → Unexercised tokens return to creator

5. EMERGENCY (30 days after expiration)
   Anyone can call emergencyFinalize()
   → Prevents permanently locked tokens
```

### Key Design Decisions

- **No oracles** — creator sets their own strike price freely; the market self-regulates.
- **Manual exercise** — the holder decides when to exercise; no automation forces decisions.
- **Fee isolation per vault** — `lockedTakerFee` and `lockedMakerFee` are written into the vault struct at creation. Global fee changes only affect future vaults.
- **Two independent fees** — `takerFee` (paid by exerciser on top of `amountRequired`) and `makerFee` (deducted from what the creator receives). Both capped at 1% (100 bps), initialized at 0%.
- **Fee-on-transfer protection** — measures `balanceOf` before and after deposit; reverts if amounts differ.
- **Marketplace is approval-based** — VaultKeys remain in the seller's wallet until purchase.
- **BuyOrderBook is escrow-based** — buyer deposits payment into the contract, guaranteeing funds exist at fill time.

---

## Deployed Contracts (Arbitrum Sepolia Testnet)

| Contract | Address |
|----------|---------|
| SwapVaultFactory | `0x74f46B61C70E9bC56bC2361f173A7A4733678fFc` |
| VaultViewer | `0xF604E47d12B89468788DF6993d2E3910ff38AF9a` |
| VaultKeyMarketplace | `0xA82483CF099e135Cf05e8648E386Db0Ab452356e` |
| BuyOrderBook | `0x79704878205630867F5160742bB4711cbCc0B3E8` |

**Chain ID:** 421614 (Arbitrum Sepolia)  
**Explorer:** https://sepolia.arbiscan.io

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Smart contracts | Solidity ^0.8.20 / ^0.8.28 |
| Testing (Solidity) | Foundry |
| Testing (TypeScript) | Hardhat v3 + Mocha/Chai |
| Libraries | OpenZeppelin Contracts v5 |
| Network | Arbitrum (L2) |

---

## Setup

**Requirements:** Node.js v20+, Foundry

```bash
# Clone and install
git clone <repo-url>
cd simples
npm install

# Compile contracts
npm run compile

# Run all tests (Hardhat)
npm run test

# Run Foundry tests
cd packages/contracts
forge test

# Run Foundry tests with verbosity
forge test -vvv
```

### Environment variables

Create `packages/contracts/.env`:

```bash
DEPLOYER_PRIVATE_KEY=0x...
ARBITRUM_SEPOLIA_RPC=https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY
```

---

## Test Coverage

**299 tests, 0 failures** across two test frameworks.

| File | Framework | Scope |
|------|-----------|-------|
| `SwapVaultFactory.t.sol` | Foundry | Creation, admin, view functions |
| `Exercise.t.sol` | Foundry | Exercise with taker/maker fees, edge cases |
| `FuzzExercise.t.sol` | Foundry | Proportional arithmetic, fee calculation (256 runs each) |
| `Finalization.t.sol` | Foundry | Finalization and emergency finalize |
| `ViewFunctions.t.sol` | Foundry | VaultViewer batch queries |
| `VaultKey.t.sol` | Foundry | ERC-20 compliance, burn restrictions |
| `VaultKeyMarketplace.t.sol` | Foundry | Listings, tiers, gasless purchases |
| `BuyOrderBook.t.sol` | Foundry | Order CRUD, fees, view functions |
| `full-lifecycle.ts` | Hardhat | End-to-end: create → sell → exercise → finalize |
| `fee-lifecycle.ts` | Hardhat | Fee locking, taker/maker fee scenarios |
| `multiple-exercisers.ts` | Hardhat | Multiple buyers exercising the same vault |
| `expiration-scenarios.ts` | Hardhat | 7 time-based scenarios |
| `fee-on-transfer.ts` | Hardhat | Fee-on-transfer token protection |
| `reentrancy.ts` | Hardhat | Reentrancy guard validation |
| `rounding-attack.ts` | Hardhat | Token conservation under fractional exercises |
| `vault-viewer.ts` | Hardhat | VaultViewer integration |
| `buy-order-book.ts` | Hardhat | BuyOrderBook integration (36 tests) |

---

## License

MIT
