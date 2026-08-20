// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end scenarios for `routed_stake`'s full use-case scope, run under
/// `sui::test_scenario`: real transaction boundaries, distinct senders, and
/// every shared object genuinely shared and re-accessed via `take_shared` —
/// exactly as the production shape composes it (the parent is shared, and
/// `parent.uid_mut()` remains the cap-gated extension surface afterward).
///
/// `routed_stake` is parent-agnostic: any UID-bearing object can host a
/// routed stake. `Parent`/`Asset` below stand in for that real parent (e.g. a
/// composition and the recording its rewards are routed from) — minimal
/// shared, key-only objects whose only job is to hand out `&mut UID`.
///
/// Scope: create → share → register → sweep (permissionless, stranger
/// sender) → unregister → unstake → restake, across transaction boundaries.
#[test_only]
module routed_stake::routed_stake_e2e_tests;

use routed_stake::routed_stake::{
    Self,
    RoutedStake,
    RoutedStakeSweptEvent,
    RoutedStakeUnstakedEvent,
};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::event;
use sui::test_scenario::{Self, Scenario};

// Phantom marker types.
public struct ASSET_SHARE {}
public struct PARENT_SHARE {}
public struct USD {}

// Actors. ADMIN performs the cap-gated setup (standing in for the parent's
// own cap-gated extension logic); STRANGER owns nothing and proves the
// permissionless sweep.
const ADMIN: address = @0xAD;
const STRANGER: address = @0x51;

/// Stand-ins for "any UID-bearing parent" — key-only, sharable, and nothing
/// else. `routed_stake` never inspects the parent's identity beyond its UID.
public struct Parent has key {
    id: UID,
}

public struct Asset has key {
    id: UID,
}

/// ADMIN's cap-gated setup: a parent and an asset, a stake pool derived from
/// the asset, a routed pool derived from the parent, and a routed stake
/// (wrapping 1000 ASSET_SHARE) registered with the stake pool. Everything is
/// shared, as production requires for `sweep` to reach it permissionlessly.
fun setup_shared(ts: &mut Scenario): ID {
    let mut parent = Parent { id: object::new(ts.ctx()) };
    let mut asset = Asset { id: object::new(ts.ctx()) };
    let parent_id = parent.id.to_inner();

    let mut stake_pool = pool::new<ASSET_SHARE, USD>(&mut asset.id);
    let routed_pool = pool::new<PARENT_SHARE, USD>(&mut parent.id);
    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent.id,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ts.ctx(),
    );
    routed.register(&mut parent.id, &mut stake_pool);

    stake_pool.share();
    routed_pool.share();
    routed_stake::share(routed);
    transfer::share_object(parent);
    transfer::share_object(asset);

    parent_id
}

/// The flagship path: a stranger sweeps the routed stake's accrued rewards
/// straight into the parent's shared pool, where a registered holder claims
/// them — no capability anywhere in the permissionless leg.
#[test]
fun stranger_sweeps_into_shared_parent_pool() {
    let mut ts = test_scenario::begin(ADMIN);
    let parent_id = setup_shared(&mut ts);

    // --- Tx 2 (ADMIN): a fan registers in the parent's pool so the swept
    // deposit is attributable ---
    ts.next_tx(ADMIN);
    let mut routed_pool = ts.take_shared<RoyaltyPool<PARENT_SHARE, USD>>();
    let mut holder = stake::new(balance::create_for_testing<PARENT_SHARE>(100), ts.ctx());
    routed_pool.register_stake(&mut holder);
    test_scenario::return_shared(routed_pool);

    // --- Tx 3 (ADMIN): fund the stake pool the routed stake earns from ---
    ts.next_tx(ADMIN);
    let mut stake_pool = ts.take_shared<RoyaltyPool<ASSET_SHARE, USD>>();
    stake_pool.deposit(balance::create_for_testing<USD>(500));
    test_scenario::return_shared(stake_pool);

    // --- Tx 4 (STRANGER, owns nothing): the permissionless sweep ---
    ts.next_tx(STRANGER);
    let mut stake_pool = ts.take_shared<RoyaltyPool<ASSET_SHARE, USD>>();
    let mut routed_pool = ts.take_shared<RoyaltyPool<PARENT_SHARE, USD>>();
    let mut routed = ts.take_shared<RoutedStake<ASSET_SHARE, PARENT_SHARE>>();
    let routed_id = routed.id();
    routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    assert_eq!(routed_pool.balance().value(), 500);
    // The wrapped stake stayed put — sweep does not touch principal.
    assert_eq!(routed.stake().value(), 1000);

    // The sweep emits exactly one event with the full payload pinned.
    let events = event::events_by_type<RoutedStakeSweptEvent<ASSET_SHARE, PARENT_SHARE, USD>>();
    assert_eq!(events.length(), 1);
    let (event_routed_id, event_parent_id, event_value) = routed_stake::swept_event_fields(
        &events[0],
    );
    assert_eq!(event_routed_id, routed_id);
    assert_eq!(event_parent_id, parent_id);
    assert_eq!(event_value, 500);

    test_scenario::return_shared(stake_pool);
    test_scenario::return_shared(routed_pool);
    test_scenario::return_shared(routed);

    // --- Tx 5 (ADMIN): the registered holder claims the swept total ---
    ts.next_tx(ADMIN);
    let mut routed_pool = ts.take_shared<RoyaltyPool<PARENT_SHARE, USD>>();
    let reward = routed_pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 500);
    assert_eq!(routed_pool.balance().value(), 0);
    test_scenario::return_shared(routed_pool);

    destroy(reward);
    destroy(holder);
    ts.end();
}

/// The full lifecycle against shared objects across transaction boundaries:
/// unregister (after a final sweep drains claimables), unstake recovers the
/// exact principal, and restake refills the emptied wrapper for reuse —
/// exercising `share`, `unregister`, `unstake`, and `restake` all via
/// `take_shared`, the way a parent's own extension would drive them.
#[test]
fun lifecycle_exits_and_refills_across_shared_transactions() {
    let mut ts = test_scenario::begin(ADMIN);
    let _parent_id = setup_shared(&mut ts);

    // --- Tx 2 (ADMIN): nothing accrued yet, so unregister needs no sweep;
    // the wrapper returns the exact principal ---
    ts.next_tx(ADMIN);
    let mut parent = ts.take_shared<Parent>();
    let mut stake_pool = ts.take_shared<RoyaltyPool<ASSET_SHARE, USD>>();
    let mut routed = ts.take_shared<RoutedStake<ASSET_SHARE, PARENT_SHARE>>();
    let routed_id = routed.id();
    let parent_id = parent.id.to_inner();
    routed.unregister(&mut parent.id, &mut stake_pool);
    let principal = routed.unstake(&mut parent.id);
    assert_eq!(principal.value(), 1000);
    assert!(!routed.has_stake());
    assert_eq!(routed.value(), 0);

    // `unstake` emits the exact recovered principal.
    let events = event::events_by_type<RoutedStakeUnstakedEvent<ASSET_SHARE, PARENT_SHARE>>();
    assert_eq!(events.length(), 1);
    let (event_routed_id, event_parent_id, event_unstaked_value) =
        routed_stake::unstaked_event_fields(&events[0]);
    assert_eq!(event_routed_id, routed_id);
    assert_eq!(event_parent_id, parent_id);
    assert_eq!(event_unstaked_value, 1000);

    // --- same tx: the emptied wrapper's derived address persists — refill it
    // and re-register with the same stake pool ---
    routed.restake(&mut parent.id, balance::create_for_testing<ASSET_SHARE>(400), ts.ctx());
    assert_eq!(routed.value(), 400);
    routed.register(&mut parent.id, &mut stake_pool);
    assert!(routed.has_stake());

    test_scenario::return_shared(parent);
    test_scenario::return_shared(stake_pool);
    test_scenario::return_shared(routed);

    destroy(principal);
    ts.end();
}

/// `stake()` and `register`/`unregister` all abort while the wrapper is
/// empty — the shared `ENoStake` guard, exercised on a genuinely shared
/// wrapper post-`unstake`.
#[test, expected_failure(abort_code = routed_stake::ENoStake, location = routed_stake)]
fun stake_view_aborts_while_empty() {
    let mut ts = test_scenario::begin(ADMIN);
    let _parent_id = setup_shared(&mut ts);

    ts.next_tx(ADMIN);
    let mut parent = ts.take_shared<Parent>();
    let mut stake_pool = ts.take_shared<RoyaltyPool<ASSET_SHARE, USD>>();
    let mut routed = ts.take_shared<RoutedStake<ASSET_SHARE, PARENT_SHARE>>();
    routed.unregister(&mut parent.id, &mut stake_pool);
    let principal = routed.unstake(&mut parent.id);
    destroy(principal);

    let _ = routed.stake();
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENoStake, location = routed_stake)]
fun register_on_empty_wrapper_aborts() {
    let mut ts = test_scenario::begin(ADMIN);
    let _parent_id = setup_shared(&mut ts);

    ts.next_tx(ADMIN);
    let mut parent = ts.take_shared<Parent>();
    let mut stake_pool = ts.take_shared<RoyaltyPool<ASSET_SHARE, USD>>();
    let mut routed = ts.take_shared<RoutedStake<ASSET_SHARE, PARENT_SHARE>>();
    routed.unregister(&mut parent.id, &mut stake_pool);
    let principal = routed.unstake(&mut parent.id);
    destroy(principal);

    // Already empty — nothing to register.
    routed.register(&mut parent.id, &mut stake_pool);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENoStake, location = routed_stake)]
fun unstake_on_empty_wrapper_aborts() {
    let mut ts = test_scenario::begin(ADMIN);
    let _parent_id = setup_shared(&mut ts);

    ts.next_tx(ADMIN);
    let mut parent = ts.take_shared<Parent>();
    let mut stake_pool = ts.take_shared<RoyaltyPool<ASSET_SHARE, USD>>();
    let mut routed = ts.take_shared<RoutedStake<ASSET_SHARE, PARENT_SHARE>>();
    routed.unregister(&mut parent.id, &mut stake_pool);
    let principal = routed.unstake(&mut parent.id);
    destroy(principal);

    // Already empty — nothing to unstake.
    let _principal = routed.unstake(&mut parent.id);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENoStake, location = routed_stake)]
fun unregister_on_empty_wrapper_aborts() {
    let mut ts = test_scenario::begin(ADMIN);
    let _parent_id = setup_shared(&mut ts);

    ts.next_tx(ADMIN);
    let mut parent = ts.take_shared<Parent>();
    let mut stake_pool = ts.take_shared<RoyaltyPool<ASSET_SHARE, USD>>();
    let mut routed = ts.take_shared<RoutedStake<ASSET_SHARE, PARENT_SHARE>>();
    routed.unregister(&mut parent.id, &mut stake_pool);
    let principal = routed.unstake(&mut parent.id);
    destroy(principal);

    // Already empty — nothing to unregister.
    routed.unregister(&mut parent.id, &mut stake_pool);
    abort
}
