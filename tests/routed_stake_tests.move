// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit-style coverage for `routed_stake`'s pure abort/logic paths: wrong
/// `&mut UID` credential, wrong-typed/foreign pool, double-claim of a derived
/// address, and lifecycle state errors (`ENoStake`/`EStakeExists`). None of
/// these gate on *sender* — `routed_stake` has no capability object of its
/// own, only object-identity checks against the `&mut UID` a caller happens
/// to hold — so a single-transaction `tx_context::dummy()` proves them just
/// as faithfully as a multi-actor scenario would. The genuinely
/// ownership-shaped flows (shared objects, `take_shared`, the permissionless
/// `sweep` by a stranger sender) live in `routed_stake_e2e_tests`.
#[test_only]
module routed_stake::routed_stake_tests;

use routed_stake::routed_stake::{Self, RoutedStake};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::event;

// Mirrored from royalty_pool::pool (private there).
const EPoolNotDerivedFromParent: u64 = 0;
// Mirrored from royalty_pool::stake (private there).
const EPoolsRegistered: u64 = 1;

// Phantom marker types for the share/currency parameters.
public struct ASSET_SHARE {}
public struct PARENT_SHARE {}
public struct USD {}

/// The real topology in miniature: the pool the routed stake earns from
/// (`stake_pool`) is derived from the ASSET object (e.g. a recording), while
/// the pool rewards are routed to (`routed_pool`) is derived from the PARENT
/// (e.g. a composition) — the same parent the routed stake derives from.
fun setup(
    ctx: &mut TxContext,
): (UID, UID, RoyaltyPool<ASSET_SHARE, USD>, RoyaltyPool<PARENT_SHARE, USD>) {
    let mut asset = object::new(ctx);
    let mut parent = object::new(ctx);
    let stake_pool = pool::new<ASSET_SHARE, USD>(&mut asset);
    let routed_pool = pool::new<PARENT_SHARE, USD>(&mut parent);
    (asset, parent, stake_pool, routed_pool)
}

#[test]
fun sweep_routes_rewards_to_the_parent_pool() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    assert_eq!(routed.id().to_address(), routed_stake::derived_address<ASSET_SHARE>(parent_id));
    routed.register(&mut parent, &mut stake_pool);

    // The routed stake is the sole staker in the stake pool, so it earns the
    // full deposit. A holder registers in the parent's pool so the swept
    // deposit is attributable.
    stake_pool.deposit(balance::create_for_testing<USD>(500));
    let mut holder = stake::new(balance::create_for_testing<PARENT_SHARE>(100), ctx);
    routed_pool.register_stake(&mut holder);

    routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);

    // The reward never surfaced as a free balance: it sits in the parent's
    // pool, claimable by the registered holder in full.
    assert_eq!(routed_pool.balance().value(), 500);
    let holder_reward = routed_pool.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), 500);

    // A zero-reward sweep is a no-op — no deposit, no event.
    routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    let swept = event::events_by_type<
        routed_stake::RoutedStakeSweptEvent<ASSET_SHARE, PARENT_SHARE, USD>,
    >();
    assert_eq!(swept.length(), 1);

    destroy(holder_reward);
    destroy(holder);
    destroy(routed);
    destroy(stake_pool);
    destroy(routed_pool);
    asset.delete();
    parent.delete();
}

#[test]
fun lifecycle_unstake_round_trips_and_restake_refills() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut stake_pool);

    // Nothing accrued → unregister needs no sweep; principal round-trips.
    routed.unregister(&mut parent, &mut stake_pool);
    let principal = routed.unstake(&mut parent);
    assert_eq!(principal.value(), 1000);
    assert!(!routed.has_stake());
    assert_eq!(routed.value(), 0);

    // The emptied wrapper persists (its derived address is burned forever)
    // and can be refilled.
    routed.restake(&mut parent, balance::create_for_testing<ASSET_SHARE>(700), ctx);
    assert_eq!(routed.value(), 700);
    routed.register(&mut parent, &mut stake_pool);

    destroy(principal);
    destroy(routed);
    destroy(stake_pool);
    destroy(routed_pool);
    asset.delete();
    parent.delete();
}

#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun sweep_rejects_wrong_parent_id() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // A forged parent id fails the wrapper's own derivation check.
    routed.sweep(&mut stake_pool, &mut routed_pool, asset.to_inner());
    abort
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = royalty_pool::pool)]
fun sweep_rejects_foreign_routed_pool() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();
    // An attacker's same-typed pool, derived from a parent they control.
    let mut attacker_parent = object::new(ctx);
    let mut attacker_pool = pool::new<PARENT_SHARE, USD>(&mut attacker_parent);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // The type checks pass; the destination's derivation does not.
    routed.sweep(&mut stake_pool, &mut attacker_pool, parent_id);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun register_rejects_wrong_parent_credential() {
    let ctx = &mut tx_context::dummy();
    let (mut asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // Control of some other UID is not authority over this wrapper.
    routed.register(&mut asset, &mut stake_pool);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun unstake_rejects_wrong_parent_credential() {
    let ctx = &mut tx_context::dummy();
    let (mut asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    let _principal = routed.unstake(&mut asset);
    abort
}

#[test, expected_failure(abort_code = EPoolsRegistered, location = royalty_pool::stake)]
fun unstake_while_registered_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut stake_pool);

    // Still registered → stake::destroy aborts EPoolsRegistered.
    let _principal = routed.unstake(&mut parent);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENoStake, location = routed_stake)]
fun sweep_without_stake_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    destroy(routed.unstake(&mut parent));

    routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    abort
}

#[test, expected_failure(abort_code = routed_stake::EStakeExists, location = routed_stake)]
fun restake_while_stake_exists_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    routed.restake(&mut parent, balance::create_for_testing<ASSET_SHARE>(1), ctx);
    abort
}

// Claiming the same (parent, StakeShare) derived address twice aborts inside
// the framework's `derived_object::claim` — the burned-address property the
// module doc relies on.
#[test, expected_failure]
fun new_twice_for_same_parent_and_share_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let _routed_a = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    // Even a different PoolShare phantom cannot re-claim the address: the key
    // encodes only StakeShare.
    let _routed_b = routed_stake::new<ASSET_SHARE, ASSET_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    abort
}
