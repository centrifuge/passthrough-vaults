# Passthrough Vaults

A passthrough vault is an immutable, non-custodial contract that lets many investors deposit into and redeem from a Centrifuge vault. Requests are forwarded directly to the underlying vault and settled in order. Investors receive the actual share token and the passthrough vault never holds funds on their behalf. Because the passthrough vault is the sole participant in the underlying, it can enforce its own investor permissions independently of the underlying vault's permissions.

## Overview

Two underlying vault types are supported:

| Underlying | `asyncDeposit` flag | Deposit flow | Redeem flow |
|---|---|---|---|
| `SyncDepositVault` | `false` | Immediate deposit into the vault | Async request → wait → redeem |
| `AsyncVault` | `true` | Async request → wait → deposit to claim | Async request → wait → redeem |

The contract is fully immutable: no admin functions, no upgrades, no owner. However, its operation and trust model follows that of the underlying Centrifuge vault and the Centrifuge protocol. Standard pool-operator and protocol actions — membership changes, vault migrations, protocol upgrades — apply to the PassthroughVault just as they would to any other participant in the underlying vault.

## Files

```
src/
  PassthroughVault.sol       — vault + factory
  interfaces/
    IPassthroughVault.sol    — external interface
    IUnderlyingVault.sol     — interface the vault calls on the underlying
  libraries/
    QueueLib.sol             — FIFO queue math
```

## Deposit flows

### Sync deposit (`asyncDeposit = false`)

```
investor → deposit(assets, receiver)
         → pulls assets from msg.sender
         → calls vault.deposit on underlying
         → transfers shares to receiver
```

### Async deposit (`asyncDeposit = true`)

```
investor → requestDeposit(assets, controller, owner)
         → pulls assets from owner
         → queues position in depositPosition[controller]
         → calls vault.requestDeposit on underlying

         [underlying settlement]

investor → deposit(assets, receiver, controller)
         → calls vault.deposit to claim from underlying
         → transfers shares to receiver
```

`deposit(type(uint256).max, receiver, controller)` claims all claimable assets.

Cancellation of pending deposit requests is not supported.

## Redeem flow (always async)

```
investor → requestRedeem(shares, controller, owner)
         → pulls shares from owner
         → queues position in redeemPosition[controller]
         → calls vault.requestRedeem on underlying

         [underlying settlement]

investor → redeem(shares, receiver, controller)
         → calls vault.redeem to claim from underlying
         → transfers assets to receiver
```

`redeem(type(uint256).max, receiver, controller)` claims all claimable shares.

Cancellation of pending redeem requests is not supported.

## Queue mechanics

Each direction (deposit, redeem) maintains a global monotonic counter (`cumulativeDepositRequested` / `cumulativeRedeemRequested`) and a per-investor `QueuePosition{rangeStart, pending}`.

On `requestDeposit`/`requestRedeem` the investor's segment is placed at the back of the queue. On settlement the underlying vault reports the cumulative settled amount via `maxDeposit`/`maxRedeem`. The `claimable` amount for an investor is the overlap between their segment and the settled window:

```
claimable = min(pending, max(0, settled − rangeStart))
```

**Re-requesting before claiming** (re-queuing): if an investor requests again while they have an unsettled remainder, the remainder carries forward and the new amount is appended. The unsettled remainder produces an orphaned segment that is eventually settled; only this investor is delayed, no other investor is affected.

**Force-claim on re-request**: when an investor calls `requestDeposit`/`requestRedeem` and has a claimable balance, it is automatically claimed to them before their position is re-queued. This avoids silent loss of a settled position.

`_getCumulativeDepositSettled()` = `vault.maxDeposit(address(this)) + totalDepositClaimed`  
`_getCumulativeRedeemSettled()` = `vault.maxRedeem(address(this)) + totalRedeemClaimed`

## Price mechanics

Share prices on async deposit and redeem are derived from the settled `maxMint / maxDeposit` and `maxWithdraw / maxRedeem` ratios at the time of claiming. This causes price blending across all claimable amounts: investors who claim at the same time receive the same blended price, regardless of when they originally submitted their request, or when their request became claimable.

## Access control

### Memberlist

An optional `IERC7714` memberlist can be set at construction (pass `address(0)` to allow all). Membership is checked on the **controller** for all state-mutating calls, including claim paths (`deposit`, `redeem`). Revocation freezes in-flight claims: if a controller is removed from the memberlist after submitting a request but before claiming, their settled position is inaccessible until re-admitted.

### Controller rules

| Function | Caller requirement |
|---|---|
| `requestDeposit` | `controller == msg.sender` |
| `requestRedeem` | `controller == msg.sender` |
| `deposit(3-arg)` | `controller == msg.sender` OR (`claimForAll && controller == receiver`) |
| `redeem` | `controller == msg.sender` OR (`claimForAll && controller == receiver`) |

`claimForAll` enables permissionless claiming: anyone can claim on behalf of a controller, but the proceeds must go to the controller themselves (`receiver == controller`).

Operator delegation (ERC-7540 operators) is not supported.

## Factory

`PassthroughVaultFactory.newVault(vault, memberlist, asyncDeposit, claimForAll)` deploys a `PassthroughVault` via `CREATE2` (salt = `keccak256(abi.encode(vault, memberlist, asyncDeposit, claimForAll))`). The deterministic address can be computed without deploying via `getVaultAddress`.

## Building and testing

```shell
forge build
forge test
```
