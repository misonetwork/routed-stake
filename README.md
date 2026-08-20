# `routed_stake`

> A stake whose rewards are irrevocably routed to its parent's royalty pool. The shared primitive behind trustless "entity earns on shares it owns" custody (`composition_routed_stake`).

**Layer:** `lib` — a primitive, not core protocol and not an extension (it attaches to nothing miso-specific). Like `royalty_pool`, it is parent-agnostic: a `RoutedStake<StakeShare, PoolShare>` is a derived object of any UID-bearing parent.

A `RoutedStake` wraps a `royalty_pool::stake::Stake<StakeShare>` — shares of some other asset that the parent owns — and commits the rewards that stake earns to the parent's own `RoyaltyPool<PoolShare, Currency>`. The wrapper exists precisely so the raw `Stake` is never exposed: a bare shared `Stake` would let any caller claim its rewards and keep them. Because the route is fixed, the wrapper is safe to share — `sweep` is permissionless, and it does not matter who calls it, since the money can only go one place.

`sweep`'s destination cannot be forged: the caller supplies the parent id, but both the wrapper's own address and the destination pool's address must derive from it (`derived_object` addresses are deterministic and collision-resistant), so a same-typed pool parented anywhere else is rejected.

Lifecycle operations take the parent's `&mut UID` as the credential — cap-gating happens at the parent, exactly as with `RoyaltyPool` creation. `register`/`unregister` are gated because a stake registers at most once per `Currency`: a permissionless register could grief by binding the stake to a garbage same-typed pool. The wrapper is never deleted: its derived address is burned forever at claim, so `unstake` empties it and `restake` refills it.

## API

- **`routed_stake::new<StakeShare, PoolShare>(parent, balance, ctx)`** — claims the derived object and wraps `balance` as the staked position; `share` makes it publicly sweepable.
- **`routed_stake::register` / `unregister`** — parent-gated; binds/unbinds the position to the pool it earns from. Unregister requires rewards drained to zero (a final `sweep`) first.
- **`routed_stake::sweep<StakeShare, PoolShare, Currency>(stake_pool, routed_pool, parent_id)`** — permissionless; claims accrued rewards and deposits them into the parent's pool. Zero rewards are a no-op; positive rewards abort if the destination pool has no registered stakes yet (they stay claimable until it does).
- **`routed_stake::unstake` / `restake`** — parent-gated; removes the position and returns its principal `Balance` / refills the emptied wrapper.
- **`routed_stake::derived_address<StakeShare>(parent_id)`** — the wrapper's deterministic address; `assert_derived_from` verifies it on-chain.
- Views: `id`, `has_stake`, `value`, `stake` (read-only, e.g. for `pool::pending_rewards`).

## Dependencies

- **`royalty_pool`** — `stake::Stake` (the wrapped position) and `pool::RoyaltyPool` (both the source and destination of `sweep`). Public API only; no package-private coupling.

## Build & test

```sh
sui move build
sui move test
```
