// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A stake whose rewards are irrevocably routed to its parent's royalty pool.
///
/// A `RoutedStake<StakeShare, PoolShare>` is a derived object of any
/// UID-bearing parent (same pattern as `RoyaltyPool`). It wraps a
/// `Stake<StakeShare>` — shares of some other asset that the parent owns —
/// and commits the rewards that stake earns to the parent's own
/// `RoyaltyPool<PoolShare, Currency>`: `sweep` is the only reachable claim
/// path, and it deposits straight into the pool derived from the same parent.
/// The wrapper exists precisely so the raw `Stake` is never exposed — a bare
/// shared `Stake` would let any caller claim its rewards and keep them.
///
/// Because the route is fixed, the wrapper is safe to share: `sweep` is
/// permissionless, and it does not matter who calls it, since the money can
/// only go one place. Lifecycle operations (`register`, `unregister`,
/// `unstake`, `restake`) instead require the parent's `&mut UID` as the
/// credential — cap-gating happens at the parent, exactly as with
/// `RoyaltyPool` creation. `register`/`unregister` are gated because a stake
/// registers at most once per `Currency`: a permissionless register could
/// grief by binding the stake to a garbage same-typed pool, permanently
/// blocking the real one for that currency.
///
/// The derivation key encodes only `StakeShare` — at most one routed stake
/// per `(parent, StakeShare)` pair, whatever `PoolShare` it used (the same
/// burned-by-first-claim consequence as `RoyaltyPoolKey`; the parent's
/// cap-gated extension is expected to pin `PoolShare` to the parent's own
/// share type). For the same reason the wrapper is never deleted: `unstake`
/// empties it and `restake` refills it, so the one derived address per pair
/// stays usable forever.
module routed_stake::routed_stake;

use royalty_pool::pool::RoyaltyPool;
use royalty_pool::stake::{Self, Stake};
use sui::balance::Balance;
use sui::derived_object::{claim, derive_address};
use sui::event::emit;

// === Errors ===

const ENotDerivedFromParent: u64 = 0;
const ENoStake: u64 = 1;
const EStakeExists: u64 = 2;

// === Structs ===

public struct RoutedStake<phantom StakeShare, phantom PoolShare> has key {
    id: UID,
    /// The wrapped position. `None` between `unstake` and `restake`; the
    /// wrapper itself persists because its derived address can never be
    /// re-claimed.
    stake: Option<Stake<StakeShare>>,
}

/// Key used to derive a routed stake's object ID from its parent UID.
public struct RoutedStakeKey<phantom StakeShare>() has copy, drop, store;

// === Events ===

public struct RoutedStakeCreatedEvent<phantom StakeShare, phantom PoolShare> has copy, drop {
    routed_stake_id: ID,
    parent_id: ID,
    staked_value: u64,
}

public struct RoutedStakeSweptEvent<phantom StakeShare, phantom PoolShare, phantom Currency> has copy, drop {
    routed_stake_id: ID,
    parent_id: ID,
    value: u64,
}

public struct RoutedStakeUnstakedEvent<phantom StakeShare, phantom PoolShare> has copy, drop {
    routed_stake_id: ID,
    parent_id: ID,
    unstaked_value: u64,
}

public struct RoutedStakeRestakedEvent<phantom StakeShare, phantom PoolShare> has copy, drop {
    routed_stake_id: ID,
    parent_id: ID,
    staked_value: u64,
}

// === Public Functions ===

/// Construct a routed stake as a derived object of `parent`, wrapping
/// `balance` as its staked position. Aborts (in `stake::new`) on a zero
/// balance, and (in `derived_object::claim`) if the `(parent, StakeShare)`
/// address was already claimed.
///
/// Cap-gating happens at the parent: callers must obtain `&mut UID` via
/// whatever cap-gated accessor the parent exposes.
public fun new<StakeShare, PoolShare>(
    parent: &mut UID,
    balance: Balance<StakeShare>,
    ctx: &mut TxContext,
): RoutedStake<StakeShare, PoolShare> {
    let parent_id = parent.to_inner();
    let routed = RoutedStake<StakeShare, PoolShare> {
        id: claim(parent, RoutedStakeKey<StakeShare>()),
        stake: option::some(stake::new(balance, ctx)),
    };

    emit(RoutedStakeCreatedEvent<StakeShare, PoolShare> {
        routed_stake_id: object::id(&routed),
        parent_id,
        staked_value: routed.value(),
    });

    routed
}

/// Share the routed stake so anyone can `sweep` it.
public fun share<StakeShare, PoolShare>(self: RoutedStake<StakeShare, PoolShare>) {
    transfer::share_object(self);
}

// Lifecycle (parent-gated)

/// Register the wrapped stake with the pool it earns from, so future
/// deposits accrue to it. Which same-typed pool is the *correct* one is the
/// caller's concern — the parent's extension is expected to pin it (e.g. by
/// derivation from the asset object) before delegating here.
public fun register<StakeShare, PoolShare, Currency>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    parent: &mut UID,
    stake_pool: &mut RoyaltyPool<StakeShare, Currency>,
) {
    self.assert_derived_from(parent.to_inner());
    assert!(self.stake.is_some(), ENoStake);
    stake_pool.register_stake(self.stake.borrow_mut());
}

/// Unregister the wrapped stake from a pool it earns from. The pool requires
/// claimable rewards to be drained to zero first — i.e. a final `sweep` —
/// so accrued rewards provably reach the parent's pool before the position
/// can move.
public fun unregister<StakeShare, PoolShare, Currency>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    parent: &mut UID,
    stake_pool: &mut RoyaltyPool<StakeShare, Currency>,
) {
    self.assert_derived_from(parent.to_inner());
    assert!(self.stake.is_some(), ENoStake);
    stake_pool.unregister_stake(self.stake.borrow_mut());
}

/// Remove the staked position and return its principal. Aborts (in
/// `stake::destroy`) while any pool registrations remain. The emptied
/// wrapper persists — its derived address is burned forever, so deleting it
/// would permanently destroy the parent's ability to route-stake this share
/// type; `restake` refills it instead.
public fun unstake<StakeShare, PoolShare>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    parent: &mut UID,
): Balance<StakeShare> {
    self.assert_derived_from(parent.to_inner());
    assert!(self.stake.is_some(), ENoStake);
    let balance = self.stake.extract().destroy();

    emit(RoutedStakeUnstakedEvent<StakeShare, PoolShare> {
        routed_stake_id: object::id(self),
        parent_id: parent.to_inner(),
        unstaked_value: balance.value(),
    });

    balance
}

/// Refill an emptied wrapper with a new staked position. Aborts if a
/// position is already present.
public fun restake<StakeShare, PoolShare>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    parent: &mut UID,
    balance: Balance<StakeShare>,
    ctx: &mut TxContext,
) {
    self.assert_derived_from(parent.to_inner());
    assert!(self.stake.is_none(), EStakeExists);
    self.stake.fill(stake::new(balance, ctx));

    emit(RoutedStakeRestakedEvent<StakeShare, PoolShare> {
        routed_stake_id: object::id(self),
        parent_id: parent.to_inner(),
        staked_value: self.value(),
    });
}

// Sweep (permissionless)

/// Claim the wrapped stake's accrued rewards from `stake_pool` and deposit
/// them into `routed_pool` — the parent's own pool. Permissionless: the
/// caller supplies `parent_id`, but cannot lie, because both the wrapper's
/// own address and `routed_pool`'s address must derive from it. A zero
/// reward is a no-op (no event), so the call composes safely into batch
/// PTBs; a positive reward aborts (in `royalty_pool::pool`) if `routed_pool`
/// has no registered stakes — the reward stays claimable here until it does.
public fun sweep<StakeShare, PoolShare, Currency>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    stake_pool: &mut RoyaltyPool<StakeShare, Currency>,
    routed_pool: &mut RoyaltyPool<PoolShare, Currency>,
    parent_id: ID,
) {
    self.assert_derived_from(parent_id);
    routed_pool.assert_derived_from(parent_id);
    assert!(self.stake.is_some(), ENoStake);

    let reward = stake_pool.claim_rewards(self.stake.borrow_mut());
    let value = reward.value();

    if (value > 0) {
        routed_pool.deposit(reward);
        emit(RoutedStakeSweptEvent<StakeShare, PoolShare, Currency> {
            routed_stake_id: object::id(self),
            parent_id,
            value,
        });
    } else {
        reward.destroy_zero();
    };
}

// === View Functions ===

public fun has_stake<StakeShare, PoolShare>(self: &RoutedStake<StakeShare, PoolShare>): bool {
    self.stake.is_some()
}

/// Staked principal, or 0 while the wrapper is empty.
public fun value<StakeShare, PoolShare>(self: &RoutedStake<StakeShare, PoolShare>): u64 {
    if (self.stake.is_some()) self.stake.borrow().value() else 0
}

/// Read-only access to the wrapped stake, e.g. for `pool::pending_rewards`.
/// Aborts while the wrapper is empty (`has_stake` to guard).
public fun stake<StakeShare, PoolShare>(
    self: &RoutedStake<StakeShare, PoolShare>,
): &Stake<StakeShare> {
    assert!(self.stake.is_some(), ENoStake);
    self.stake.borrow()
}

/// Compute the deterministic address of a routed stake given its parent ID
/// and `StakeShare` type parameter.
public fun derived_address<StakeShare>(parent_id: ID): address {
    derive_address(parent_id, RoutedStakeKey<StakeShare>())
}

/// Verify the routed stake was derived from the given parent ID.
public fun assert_derived_from<StakeShare, PoolShare>(
    self: &RoutedStake<StakeShare, PoolShare>,
    parent_id: ID,
) {
    assert!(
        self.id.to_address() == derive_address(parent_id, RoutedStakeKey<StakeShare>()),
        ENotDerivedFromParent,
    );
}

// === Test Functions ===

/// Test-only accessor for `RoutedStakeSweptEvent`'s payload — the struct's
/// fields are module-private and the event carries no other public reader.
#[test_only]
public fun swept_event_fields<StakeShare, PoolShare, Currency>(
    event: &RoutedStakeSweptEvent<StakeShare, PoolShare, Currency>,
): (ID, ID, u64) {
    (event.routed_stake_id, event.parent_id, event.value)
}

/// Test-only accessor for `RoutedStakeUnstakedEvent`'s payload.
#[test_only]
public fun unstaked_event_fields<StakeShare, PoolShare>(
    event: &RoutedStakeUnstakedEvent<StakeShare, PoolShare>,
): (ID, ID, u64) {
    (event.routed_stake_id, event.parent_id, event.unstaked_value)
}
