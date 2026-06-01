# Passthrough Vaults

A passthrough vault is an immutable, non-custodial contract that lets many investors deposit into and redeem from a Centrifuge vault. Requests are forwarded directly to the underlying vault and settled in order. Investors receive the actual share token and the passthrough vault never holds funds on their behalf. Because the passthrough vault is the sole participant in the underlying, it can enforce its own investor permissions independently of the underlying vault's permissions.

## Overview

Two underlying vault types are supported:

| Underlying | `asyncDeposit` flag | Deposit flow | Redeem flow |
|---|---|---|---|
| `SyncDepositVault` | `false` | Immediate deposit into the vault | Async request → wait → redeem |
| `AsyncVault` | `true` | Async request → wait → deposit to claim | Async request → wait → redeem |

The contract is fully immutable: no admin functions, no upgrades, no owner. However, its operation and trust model follows that of the underlying Centrifuge vault and the Centrifuge protocol. Standard pool-operator and protocol actions (e.g. membership changes, vault migrations, protocol upgrades) apply to the PassthroughVault just as they would to any other participant in the underlying vault. Notably, Centrifuge governance can cancel the passthrough's pending requests on the underlying. The cancelled funds would then sit in a claimable-cancel balance that the passthrough has no function to reach. Therefore, such cancellations must be coordinated with the passthrough's operators.

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

**Rounding dust**: rounding in the underlying vault's claim accounting is pushed to the last investor in each settled range. That investor may see a small non-zero `pendingDepositRequest` or `pendingRedeemRequest` that cannot yet be claimed; it clears on the next fulfillment, but can remain stuck indefinitely if no further fulfillment arrives.

## Price mechanics

Share prices on async deposit and redeem are derived from the settled `maxMint / maxDeposit` and `maxWithdraw / maxRedeem` ratios at the time of claiming. This causes price blending across all claimable amounts: investors who claim at the same time receive the same blended price, regardless of when they originally submitted their request, or when their request became claimable.

Because the price is blended at claim time, when an investor claims matters. A settled position left unclaimed stays in the shared pool and is re-priced by later fulfillments: if the price rises between an investor's fulfillment and their claim they receive more than their own epoch settled at, and if it falls they receive less, in both cases at the expense (or to the benefit) of whoever claims around them. Deployments that want to remove this timing game should set `claimForAll = true` so a keeper can force every settled position to be claimed promptly; `claimForAll` is fixed at construction and cannot be changed later.

All investors also share a single request slot on the underlying vault. A request placed in the window between the hub approving a batch and notifying this vault can be deferred to the next epoch, so an individual investor may occasionally wait one extra epoch even when nothing is wrong.

## Access control

### Memberlist

An optional `IERC7714` memberlist can be set at construction (pass `address(0)` to allow all). Membership is checked on the **controller** for all state-mutating calls, including claim paths (`deposit`, `redeem`). Revocation freezes in-flight claims: if a controller is removed from the memberlist after submitting a request but before claiming, their settled position is inaccessible until re-admitted. This holds even when `claimForAll = true` because the gate is on the controller, so a keeper cannot claim for a revoked controller either, and the revoked controller's stuck redeem position keeps contributing to the blended redeem price for everyone else until it is re-admitted and drained.

The memberlist is the passthrough's own access gate and is independent of the underlying vault's restrictions, i.e. the passthrough does not check whether the caller, controller or receiver is permitted on the underlying. A passthrough deployed with `address(0)` (or a permissive memberlist) therefore lets anyone interact with the underlying through it, including addresses the underlying's own memberlist would reject.

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

The factory is permissionless: anyone can deploy a PassthroughVault wrapping any address. The deployed bytecode is identical regardless of what `vault` points to. Always verify that the wrapped vault address is a legitimate Centrifuge vault before interacting with a PassthroughVault. I.e., a passthrough pointed at a malicious vault looks identical on-chain to a legitimate one but forwards every depositor's assets to that attacker-controlled contract.

## Building and testing

```shell
forge build
forge test
```
