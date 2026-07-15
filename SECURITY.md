# Security Considerations — Simples Protocol (SwapVault)

This document is intended for security researchers and auditors. It describes the threat model, security properties enforced by the contracts, known limitations, and areas that deserve extra scrutiny.

---

## Threat Model

The protocol assumes:

- **ERC-20 tokens** comply with the standard interface. Non-standard tokens (fee-on-transfer, rebasing, tokens with callbacks) are explicitly handled or rejected.
- **Users are adversarial.** No privileged role can pause vaults, drain user funds, or alter existing vault parameters.
- **The frontend is untrusted.** All security guarantees must hold at the contract level regardless of frontend behavior.

---

## Security Properties

### 1. Vault isolation

Each vault is self-contained. A compromise (e.g., a malicious token) can only affect that specific vault's funds. The factory holds all deposited tokens but each vault's accounting is independent.

### 2. Admin power is minimal and scoped

The only privileged role is `feeCollector`, which can:
- Update `takerFee` and `makerFee` (affects only **future** vaults — existing vaults lock fees at creation)
- Update the `feeCollector` address itself
- Receive protocol fees

`feeCollector` **cannot**: pause vaults, withdraw user funds, cancel exercises, modify vault parameters, or affect any vault created before a fee change.

### 3. Fee isolation per vault

`lockedTakerFee` and `lockedMakerFee` are written into the `Vault` struct at `createVault()` time. Subsequent calls to `updateTakerFee()` / `updateMakerFee()` have no effect on existing vaults. This is enforced structurally, not by access control.

### 4. Reentrancy protection

All state-changing functions (`createVault`, `exercise`, `finalizeVault`, `emergencyFinalize`) are protected by OpenZeppelin's `ReentrancyGuard`. The checks-effects-interactions pattern is followed: vault state is updated before any external token transfers.

In the `exercise()` function, the contract now acts as an intermediary for `tokenRequired` — it pulls the full amount from the taker first, then distributes to the maker and fee collector. This ordering was tested with a `MockReentrantToken` that attempts to re-enter `exercise()`.

### 5. Fee-on-transfer token rejection

`createVault()` measures the factory's `balanceOf(tokenDeposited)` before and after the transfer. If the received amount differs from the specified amount, the transaction reverts with `FeeOnTransferNotSupported()`. This prevents an attacker from creating a vault with inflated `amountDeposited`.

Note: fee-on-transfer tokens can still be used as `tokenRequired` (the payment token), since that amount is computed proportionally from the vault parameters rather than measured by balance delta.

### 6. VaultKey burn controls

`VaultKey.burn()` can only be called by the factory contract that deployed that specific VaultKey (stored as `factory` in the VaultKey constructor). This prevents unauthorized burning.

### 7. Emergency finalization

If the vault creator loses access to their wallet, tokens would be permanently locked after expiration. `emergencyFinalize()` allows anyone to trigger finalization 30 days after expiration, always returning funds to the original `vault.creator` address — not to the caller.

### 8. Integer arithmetic

All proportional calculations use the pattern `(vaultKeyAmount * total) / VAULT_KEY_SUPPLY`. Since `VAULT_KEY_SUPPLY = 100e18`, multiplication of two `uint256` values could overflow if amounts exceed `uint128` range. The fuzz test suite (`testFuzzExerciseProportions`, `testFuzzFeeCalculation`) uses `type(uint128).max` as the upper bound for deposited/required amounts and runs 256 random iterations to verify correctness.

Rounding is always in favor of the protocol (integer division truncates), meaning the exerciser never receives more than their fair share, and fees are never over-collected.

---

## Known Limitations and Out of Scope

### Rebasing tokens
Tokens whose balance changes without a transfer (e.g., stETH, aTokens) will cause accounting errors. The protocol does not detect rebasing — only fee-on-transfer is explicitly rejected. **Using rebasing tokens as `tokenDeposited` is undefined behavior.**

### ERC-777 / tokens with callbacks
Tokens that call back into the recipient on transfer could interact with `ReentrancyGuard`. The guard prevents re-entering the same contract function, but cross-contract callbacks are not explicitly handled. Such tokens are not expected to be supported.

### Oracle-free pricing means no liquidations
There is no mechanism to force exercise or close a vault based on price. This is intentional — the protocol is purely peer-to-peer. Users bear full market risk.

### Front-running of exercise
A miner or searcher can observe a pending `exercise()` transaction and front-run it. Because `exercise()` is purely user-driven (manual), this is considered acceptable — the user always controls when to exercise.

### VaultKey supply is fixed at 100
Each vault mints exactly 100 VaultKeys (with 18 decimals). This is a deliberate simplification. Fractional VaultKey amounts are supported, but the supply itself cannot be changed after deployment.

### No VaultKey burn for the creator
The protocol has no `voluntaryBurn()` function on VaultKey. Expired VaultKeys can be sent to `address(0xdead)` or a future Recycler contract. This does not affect fund safety.

### Single feeCollector — not a multisig on testnet
On Arbitrum Sepolia, `feeCollector` is a single EOA (the deployer). For mainnet, a multisig is strongly recommended.

---

## Areas of Particular Interest for Auditors

1. **`exercise()` token flow** — The function now routes `tokenRequired` through the contract itself before distributing to maker and feeCollector. Verify that: (a) the contract's intermediate balance is always fully distributed, (b) no edge case leaves `tokenRequired` stranded in the contract, and (c) `makerFeeAmount` cannot exceed `requiredAmount` (bounded by `MAX_FEE = 100` bps and the fact that `requiredAmount = vaultKeyAmount * amountRequired / VAULT_KEY_SUPPLY`).

2. **`calculateExerciseAmounts()` vs `exercise()` consistency** — The view function returns the same values that `exercise()` will use. Verify that the taker's `approve()` amount (= `totalFromTaker`) computed off-chain exactly matches what the contract will pull.

3. **VaultKey burn atomicity** — `VaultKey.burn()` is called before token transfers in `exercise()`. Verify that a failed burn (insufficient balance) reverts the entire transaction and leaves vault state unchanged.

4. **`emergencyFinalize()` access** — Confirm that anyone can call it after `expiration + EMERGENCY_DELAY` and that it always sends to `vault.creator`, never to `msg.sender`.

5. **Fee boundary enforcement** — Both `updateTakerFee()` and `updateMakerFee()` enforce `MAX_FEE = 100`. At maximum fees (takerFee=100, makerFee=100), verify: taker pays `requiredAmount * 1.01`, maker receives `requiredAmount * 0.99`, feeCollector receives `requiredAmount * 0.02`, and arithmetic does not overflow.

6. **VaultKeyMarketplace EIP-712** — Gasless listings are signed off-chain. Verify nonce management, expiry enforcement, and replay protection across chain IDs.

---

## Test Suite for Security Scenarios

| Test file | Security scenario covered |
|-----------|--------------------------|
| `reentrancy.ts` | `MockReentrantToken` attempts re-entry into `exercise()` |
| `fee-on-transfer.ts` | Tokens with 1% and 0.01% transfer fees rejected on vault creation |
| `rounding-attack.ts` | 100 sequential 1-VK exercises cannot extract more than deposited |
| `FuzzExercise.t.sol` | 256-run fuzz on proportional math and fee calculation |
| `Exercise.t.sol` | `testExerciseWithTakerFee`, `testExerciseWithMakerFee`, `testExerciseUsesLockedFeeNotCurrentFee` |
| `fee-lifecycle.ts` | Fee locking isolation, combined taker+maker fees, role transfer |

---

## Audit Scope

**In scope:**
- `SwapVaultFactory.sol`
- `VaultKey.sol`
- `VaultViewer.sol`
- `VaultKeyMarketplace.sol`
- `BuyOrderBook.sol`

**Out of scope:**
- Frontend / off-chain components
- Third-party token contracts
- OpenZeppelin library internals (ReentrancyGuard, SafeERC20, ERC20, Ownable, EIP712, ECDSA)
- Testnet deployment scripts
