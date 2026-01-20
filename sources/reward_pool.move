module reward_pool::reward_pool;

use stake::stake::{Self as stake, Stake};
use std::type_name::{TypeName, with_defining_ids};
use sui::balance::{Self, Balance, redeem_funds, withdraw_funds_from_object};
use sui::coin::Coin;
use sui::derived_object::{claim, derive_address};
use sui::event::emit;
use sui::transfer::Receiving;

//=== Structs ===

public struct RewardPool<phantom Share, phantom Currency> has key {
    id: UID,
    balance: Balance<Currency>,
    staked_shares: u64,
    cumulative_reward_per_share: u256,
    cumulative_deposits: u128,
}

/// Witness type for identifying reward pool extensions on stakes.
/// Parameterized by Currency so each pool type has a unique key.
public struct RewardPoolExtension<phantom Currency> has drop {}

/// Registration config stored as an extension on a Stake.
public struct RewardPoolRegistration<phantom Currency> has store, drop {
    pool_id: ID,
    last_claim_index: u256,
    unregister_requested_at_epoch: Option<u64>,
}

/// Key used to derive a RewardPool's object ID from a parent UID.
///
/// Uses (TypeName, TypeName) instead of phantom types <Share, Currency> to enable
/// runtime address derivation without requiring compile-time knowledge of all types.
/// This is essential for protocols that:
/// - Iterate over pools with heterogeneous share types in a single transaction
/// - Distribute funds to multiple pools without complex PTB orchestration
/// - Derive pool addresses using stored TypeName values
///
/// Type safety is preserved at pool creation (new<Share, Currency> requires actual types),
/// while lookup remains flexible. An incorrect TypeName simply yields a wrong address
/// (nothing found), not a security vulnerability.
public struct RewardPoolKey(TypeName, TypeName) has copy, drop, store;

//=== Events ===

public struct RewardPoolCreatedEvent<phantom Share, phantom Currency> has copy, drop {
    reward_pool_id: ID,
}

public struct RewardDepositedEvent<phantom Currency> has copy, drop {
    reward_pool_id: ID,
    value: u64,
}

public struct StakeRegisteredEvent<phantom Share, phantom Currency> has copy, drop {
    reward_pool_id: ID,
    stake_id: ID,
    staked_amount: u64,
}

public struct StakeUnregisterRequestedEvent<phantom Share, phantom Currency> has copy, drop {
    reward_pool_id: ID,
    stake_id: ID,
    unregister_epoch: u64,
}

public struct StakeUnregisterCanceledEvent<phantom Share, phantom Currency> has copy, drop {
    reward_pool_id: ID,
    stake_id: ID,
}

public struct StakeUnregisteredEvent<phantom Share, phantom Currency> has copy, drop {
    reward_pool_id: ID,
    stake_id: ID,
    unstaked_amount: u64,
}

public struct RewardClaimedEvent<phantom Share, phantom Currency> has copy, drop {
    reward_pool_id: ID,
    stake_id: ID,
    reward_amount: u64,
}

public struct StakedSharesIncreasedEvent<phantom Share, phantom Currency> has copy, drop {
    reward_pool_id: ID,
    previous_staked_shares: u64,
    new_staked_shares: u64,
}

public struct StakedSharesDecreasedEvent<phantom Share, phantom Currency> has copy, drop {
    reward_pool_id: ID,
    previous_staked_shares: u64,
    new_staked_shares: u64,
}

//=== Constants ===

const PRECISION: u256 = 1_000_000_000_000_000_000;
const UNREGISTER_DELAY_EPOCHS: u64 = 2;

//=== Errors ===

const EUnauthorized: u64 = 0;
const ENoStakedShares: u64 = 1;
const ENoCoinsToReceive: u64 = 2;
const EAlreadyRegistered: u64 = 3;
const ENotRegistered: u64 = 4;
const ELastClaimIndexMismatch: u64 = 5;
const EPoolIdMismatch: u64 = 6;
const EUnregisterNotRequested: u64 = 7;
const EUnregisterAlreadyRequested: u64 = 8;
const EUnregisterDelayNotElapsed: u64 = 9;

//=== Public Functions ===

public fun new<Share, Currency>(parent: &mut UID): RewardPool<Share, Currency> {
    let reward_pool = RewardPool<Share, Currency> {
        id: claim(
            parent,
            RewardPoolKey(with_defining_ids<Share>(), with_defining_ids<Currency>()),
        ),
        balance: balance::zero(),
        staked_shares: 0,
        cumulative_reward_per_share: 0,
        cumulative_deposits: 0,
    };

    emit(RewardPoolCreatedEvent<Share, Currency> {
        reward_pool_id: reward_pool.id(),
    });

    reward_pool
}

/// Share the RewardPool object.
public fun share<Share, Currency>(self: RewardPool<Share, Currency>) {
    transfer::share_object(self);
}

public fun deposit<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    balance: Balance<Currency>,
) {
    self.deposit_impl(balance);
}

/// Register a stake with the reward pool.
/// The stake must be in Locked state.
/// Adds a RewardPoolRegistration<Currency> extension to the stake.
public fun register_stake<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    stake: &mut Stake<Share>,
) {
    assert!(!stake.has_extension<Share, RewardPoolExtension<Currency>>(), EAlreadyRegistered);

    let staked_amount = stake.balance().value();

    let registration = RewardPoolRegistration<Currency> {
        pool_id: self.id(),
        last_claim_index: self.cumulative_reward_per_share,
        unregister_requested_at_epoch: option::none(),
    };

    stake.add_extension(RewardPoolExtension<Currency> {}, registration);
    self.increase_staked_shares(staked_amount);

    emit(StakeRegisteredEvent<Share, Currency> {
        reward_pool_id: self.id(),
        stake_id: stake.id(),
        staked_amount,
    });
}

/// Request to unregister a stake from the reward pool.
/// Starts the unregister delay timer.
public fun request_unregister_stake<Share, Currency>(
    self: &RewardPool<Share, Currency>,
    stake: &mut Stake<Share>,
    ctx: &TxContext,
) {
    assert!(stake.has_extension<Share, RewardPoolExtension<Currency>>(), ENotRegistered);

    let registration = stake::borrow_extension_mut<Share, RewardPoolExtension<Currency>, RewardPoolRegistration<Currency>>(RewardPoolExtension {}, stake);
    assert!(registration.pool_id == self.id(), EPoolIdMismatch);
    assert!(registration.unregister_requested_at_epoch.is_none(), EUnregisterAlreadyRequested);

    let unregister_epoch = ctx.epoch() + UNREGISTER_DELAY_EPOCHS;
    registration.unregister_requested_at_epoch = option::some(ctx.epoch());

    emit(StakeUnregisterRequestedEvent<Share, Currency> {
        reward_pool_id: self.id(),
        stake_id: stake.id(),
        unregister_epoch,
    });
}

/// Cancel a pending unregister request.
public fun cancel_unregister_stake<Share, Currency>(
    self: &RewardPool<Share, Currency>,
    stake: &mut Stake<Share>,
) {
    assert!(stake.has_extension<Share, RewardPoolExtension<Currency>>(), ENotRegistered);

    let registration = stake::borrow_extension_mut<Share, RewardPoolExtension<Currency>, RewardPoolRegistration<Currency>>(RewardPoolExtension {}, stake);
    assert!(registration.pool_id == self.id(), EPoolIdMismatch);
    assert!(registration.unregister_requested_at_epoch.is_some(), EUnregisterNotRequested);

    registration.unregister_requested_at_epoch = option::none();

    emit(StakeUnregisterCanceledEvent<Share, Currency> {
        reward_pool_id: self.id(),
        stake_id: stake.id(),
    });
}

/// Unregister a stake from the reward pool.
/// Requires unregister to have been requested and delay to have elapsed.
/// All rewards must be claimed first (last_claim_index must match current cumulative).
/// Removes the RewardPoolRegistration<Currency> extension from the stake.
public fun unregister_stake<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    stake: &mut Stake<Share>,
    ctx: &TxContext,
) {
    assert!(stake.has_extension<Share, RewardPoolExtension<Currency>>(), ENotRegistered);

    // Check unregister request and delay
    {
        let registration = stake::borrow_extension<Share, RewardPoolExtension<Currency>, RewardPoolRegistration<Currency>>(RewardPoolExtension {}, stake);
        assert!(registration.pool_id == self.id(), EPoolIdMismatch);
        assert!(registration.unregister_requested_at_epoch.is_some(), EUnregisterNotRequested);

        let requested_at = *registration.unregister_requested_at_epoch.borrow();
        assert!(ctx.epoch() >= requested_at + UNREGISTER_DELAY_EPOCHS, EUnregisterDelayNotElapsed);
    };

    let registration = stake.remove_extension<Share, RewardPoolExtension<Currency>, RewardPoolRegistration<Currency>>();
    let RewardPoolRegistration { pool_id: _, last_claim_index, .. } = registration;

    assert!(last_claim_index == self.cumulative_reward_per_share, ELastClaimIndexMismatch);

    let unstaked_amount = stake.balance().value();
    self.decrease_staked_shares(unstaked_amount);

    emit(StakeUnregisteredEvent<Share, Currency> {
        reward_pool_id: self.id(),
        stake_id: stake.id(),
        unstaked_amount,
    });
}

/// Claim accumulated rewards for a stake.
/// Updates the stake's last_claim_index to the current cumulative_reward_per_share.
public fun claim_rewards<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    stake: &mut Stake<Share>,
): Balance<Currency> {
    assert!(stake.has_extension<Share, RewardPoolExtension<Currency>>(), ENotRegistered);

    // Read balance and registration data before mutable borrow
    let staked_amount = stake.balance().value();

    let last_claim_index = {
        let registration = stake::borrow_extension<Share, RewardPoolExtension<Currency>, RewardPoolRegistration<Currency>>(RewardPoolExtension {}, stake);
        assert!(registration.pool_id == self.id(), EPoolIdMismatch);
        registration.last_claim_index
    };

    let reward_amount = calculate_reward(
        staked_amount,
        last_claim_index,
        self.cumulative_reward_per_share,
    );

    // Now mutably borrow to update
    let registration = stake::borrow_extension_mut<Share, RewardPoolExtension<Currency>, RewardPoolRegistration<Currency>>(RewardPoolExtension {}, stake);
    registration.last_claim_index = self.cumulative_reward_per_share;

    emit(RewardClaimedEvent<Share, Currency> {
        reward_pool_id: self.id(),
        stake_id: stake.id(),
        reward_amount,
    });

    self.balance.split(reward_amount)
}

/// Calculate pending rewards for a stake without claiming.
public fun pending_rewards<Share, Currency>(
    self: &RewardPool<Share, Currency>,
    stake: &Stake<Share>,
): u64 {
    if (!stake.has_extension<Share, RewardPoolExtension<Currency>>()) {
        return 0
    };

    let registration = stake::borrow_extension<Share, RewardPoolExtension<Currency>, RewardPoolRegistration<Currency>>(RewardPoolExtension {}, stake);
    if (registration.pool_id != self.id()) {
        return 0
    };

    calculate_reward(
        stake.balance().value(),
        registration.last_claim_index,
        self.cumulative_reward_per_share,
    )
}

public fun receive_and_deposit<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    coins_to_receive: vector<Receiving<Coin<Currency>>>,
) {
    assert!(!coins_to_receive.is_empty(), ENoCoinsToReceive);

    let parent = &mut self.id;
    let mut balance = balance::zero<Currency>();

    coins_to_receive.destroy!(|coin_to_receive| {
        let coin = transfer::public_receive(parent, coin_to_receive);
        balance.join(coin.into_balance());
    });

    if (balance.value() > 0) {
        self.deposit_impl(balance);
    } else {
        balance.destroy_zero();
    }
}

public fun redeem_and_deposit<Share, Currency>(self: &mut RewardPool<Share, Currency>, value: u64) {
    let withdrawal = withdraw_funds_from_object(&mut self.id, value);
    let balance = redeem_funds(withdrawal);
    self.deposit_impl(balance);
}

/// Withdraw from a reward pool.
/// Requires the parent's &mut UID to authorize the operation.
public fun withdraw<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    parent: &mut UID,
    value: Option<u64>,
): Balance<Currency> {
    self.authorize(parent);

    let value = value.destroy_or!(self.balance.value());
    self.balance.split(value)
}

public fun balance_mut<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    parent: &mut UID,
): &mut Balance<Currency> {
    self.authorize(parent);

    &mut self.balance
}

//=== Public View Functions ===

public fun id<Share, Currency>(self: &RewardPool<Share, Currency>): ID {
    self.id.to_inner()
}

public fun balance<Share, Currency>(self: &RewardPool<Share, Currency>): &Balance<Currency> {
    &self.balance
}

public fun staked_shares<Share, Currency>(self: &RewardPool<Share, Currency>): u64 {
    self.staked_shares
}

public fun cumulative_reward_per_share<Share, Currency>(self: &RewardPool<Share, Currency>): u256 {
    self.cumulative_reward_per_share
}

public fun cumulative_deposits<Share, Currency>(self: &RewardPool<Share, Currency>): u128 {
    self.cumulative_deposits
}

public fun derived_address(parent_id: ID, share_type: TypeName, currency_type: TypeName): address {
    derive_address(parent_id, RewardPoolKey(share_type, currency_type))
}

#[allow(unused_mut_parameter)]
public fun authorize<Share, Currency>(self: &RewardPool<Share, Currency>, parent: &mut UID) {
    assert!(
        self.id.to_address() == derive_address(parent.to_inner(), RewardPoolKey(with_defining_ids<Share>(), with_defining_ids<Currency>())),
        EUnauthorized,
    );
}

public fun assert_derived_from<Share, Currency>(self: &RewardPool<Share, Currency>, parent_id: ID) {
    assert!(
        self.id.to_address() == derive_address(parent_id, RewardPoolKey(with_defining_ids<Share>(), with_defining_ids<Currency>())),
        EUnauthorized,
    );
}

//=== Private Functions ===

fun increase_staked_shares<Share, Currency>(self: &mut RewardPool<Share, Currency>, value: u64) {
    let previous_staked_shares = self.staked_shares;
    let new_staked_shares = previous_staked_shares + value;

    self.staked_shares = new_staked_shares;

    emit(StakedSharesIncreasedEvent<Share, Currency> {
        reward_pool_id: self.id(),
        previous_staked_shares,
        new_staked_shares,
    });
}

fun decrease_staked_shares<Share, Currency>(self: &mut RewardPool<Share, Currency>, value: u64) {
    let previous_staked_shares = self.staked_shares;
    let new_staked_shares = previous_staked_shares - value;

    self.staked_shares = new_staked_shares;

    emit(StakedSharesDecreasedEvent<Share, Currency> {
        reward_pool_id: self.id(),
        previous_staked_shares,
        new_staked_shares,
    });
}

fun deposit_impl<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    balance: Balance<Currency>,
) {
    // Require a non-zero number of staked shares before processing deposits.
    //
    // This check serves two purposes:
    //
    // 1. Mathematical: The reward accumulator formula divides the deposit value by
    //    staked_shares. If staked_shares is zero, this would either cause a division
    //    by zero error or, if guarded, the deposit would be added to the balance
    //    without updating cumulative_reward_per_share — making those funds permanently
    //    unclaimable ("orphaned").
    //
    // 2. Economic: Reward payments sent to the pool before any shareholders have
    //    staked will remain as pending Coin objects at the pool's address OR a balance
    //    in the reward pool's balance accumulator. Once shareholders stake and call
    //    receive_and_deposit() those queued payments are processed and distributed proportionally.
    //    This ensures no rewards are lost due to timing mismatches between when payments
    //    arrive and when shareholders register their entitlements.
    //
    // Callers should check staked_shares > 0 before sending transactions, or expect
    // this to revert if no shareholders have staked yet.
    assert!(self.staked_shares > 0, ENoStakedShares);

    let deposit_value = balance.value();

    let reward_per_share = (deposit_value as u256) * PRECISION / (self.staked_shares as u256);
    self.cumulative_reward_per_share = self.cumulative_reward_per_share + reward_per_share;
    self.cumulative_deposits = self.cumulative_deposits + (deposit_value as u128);

    self.balance.join(balance);

    emit(RewardDepositedEvent<Currency> {
        reward_pool_id: self.id(),
        value: deposit_value,
    });
}

fun calculate_reward(staked_amount: u64, last_claim_index: u256, current_index: u256): u64 {
    let reward_delta = current_index - last_claim_index;
    let reward = (staked_amount as u256) * reward_delta / PRECISION;
    (reward as u64)
}
