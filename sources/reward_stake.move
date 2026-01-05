module reward_pool::reward_stake;

use reward_pool::reward_pool::RewardPool;
use std::type_name::{TypeName, with_defining_ids};
use sui::balance::{Self, Balance};
use sui::event::emit;
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

//=== Structs ===

public struct RewardStake<phantom RewardShare> has key, store {
    id: UID,
    state: RewardStakeState,
    balance: Balance<RewardShare>,
}

public enum RewardStakeState has copy, drop, store {
    Unlocked,
    Locked(VecMap<TypeName, u256>), // claim index by currency type
    Unlocking(u64), // unlock epoch
}

public struct RewardShareDepositReceipt {
    stake_id: ID,
    deposit_value: u64,
    pool_currency_types: VecSet<TypeName>,
}

//=== Events ===

public struct RewardStakeCreatedEvent has copy, drop {
    stake_id: ID,
}

public struct RewardStakeLockedEvent has copy, drop {
    stake_id: ID,
}

public struct RewardStakeLockRequestedEvent has copy, drop {
    stake_id: ID,
    unlock_epoch: u64,
}

public struct RewardStakeUnlockedEvent has copy, drop {
    stake_id: ID,
}

public struct RewardStakeUnlockCanceledEvent has copy, drop {
    stake_id: ID,
}

public struct RewardStakeRewardShareDepositEvent has copy, drop {
    stake_id: ID,
    deposit_value: u64,
}

public struct RewardStakeRewardShareWithdrawalEvent has copy, drop {
    stake_id: ID,
    withdraw_value: u64,
}

public struct RewardPoolRegisteredEvent<
    phantom RewardShare,
    phantom RewardCurrency,
> has copy, drop {
    stake_id: ID,
    reward_pool_id: ID,
}

public struct RewardPoolUnregisteredEvent<
    phantom RewardShare,
    phantom RewardCurrency,
> has copy, drop {
    stake_id: ID,
    reward_pool_id: ID,
}

//=== Constants ===

const UNLOCK_DELAY_EPOCHS: u64 = 2;

//=== Errors ===

const ENotUnlockedState: u64 = 0;
const ENotUnlockingState: u64 = 1;
const ENotLockedState: u64 = 2;
const EUnlockEpochNotReached: u64 = 3;
const EWithdrawValueExceedsBalance: u64 = 4;
const ERewardPoolAlreadyRegistered: u64 = 5;
const ERewardPoolNotRegistered: u64 = 6;
const ERegistrationsNotEmpty: u64 = 7;
const ELastClaimIndexMismatch: u64 = 8;
const EInvalidStake: u64 = 9;
const EReceiptRewardCurrencyTypeNotFound: u64 = 10;
const EReceiptRewardCurrencyTypesNotEmpty: u64 = 11;
const EUnsupportedStateForDeposit: u64 = 12;
const EZeroBalance: u64 = 13;

//=== Public Functions ===

public fun new<RewardShare>(ctx: &mut TxContext): RewardStake<RewardShare> {
    let stake = RewardStake {
        id: object::new(ctx),
        state: RewardStakeState::Unlocked,
        balance: balance::zero(),
    };

    emit(RewardStakeCreatedEvent {
        stake_id: stake.id(),
    });

    stake
}

public fun lock<RewardShare>(self: &mut RewardStake<RewardShare>) {
    match (self.state) {
        RewardStakeState::Unlocked => {
            self.state = RewardStakeState::Locked(vec_map::empty());

            emit(RewardStakeLockedEvent {
                stake_id: self.id(),
            });
        },
        _ => abort ENotUnlockedState,
    }
}

public fun request_unlock<RewardShare>(self: &mut RewardStake<RewardShare>, ctx: &TxContext) {
    match (self.state) {
        RewardStakeState::Locked(reward_pool_registrations) => {
            assert!(reward_pool_registrations.is_empty(), ERegistrationsNotEmpty);

            let unlock_epoch = ctx.epoch() + UNLOCK_DELAY_EPOCHS;
            self.state = RewardStakeState::Unlocking(unlock_epoch);

            emit(RewardStakeLockRequestedEvent {
                stake_id: self.id(),
                unlock_epoch,
            });
        },
        _ => abort ENotLockedState,
    }
}

public fun unlock<RewardShare>(self: &mut RewardStake<RewardShare>, ctx: &TxContext) {
    match (self.state) {
        RewardStakeState::Unlocking(unlock_epoch) => {
            assert!(ctx.epoch() >= unlock_epoch, EUnlockEpochNotReached);
            self.state = RewardStakeState::Unlocked;

            emit(RewardStakeUnlockedEvent {
                stake_id: self.id(),
            });
        },
        _ => abort ENotUnlockingState,
    }
}

public fun cancel_unlock<RewardShare>(self: &mut RewardStake<RewardShare>) {
    match (self.state) {
        RewardStakeState::Unlocking(_) => {
            self.state = RewardStakeState::Locked(vec_map::empty());

            emit(RewardStakeUnlockCanceledEvent {
                stake_id: self.id(),
            });
        },
        _ => abort ENotUnlockingState,
    }
}

public fun register_reward_pool<RewardShare, RewardCurrency>(
    self: &mut RewardStake<RewardShare>,
    reward_pool: &mut RewardPool<RewardShare, RewardCurrency>,
) {
    match (&mut self.state) {
        RewardStakeState::Locked(registrations) => {
            let currency_type = with_defining_ids<RewardCurrency>();
            assert!(!registrations.contains(&currency_type), ERewardPoolAlreadyRegistered);
            registrations.insert(currency_type, reward_pool.cumulative_reward_per_share());
            reward_pool.increase_staked_shares(self.balance.value());

            emit(RewardPoolRegisteredEvent<RewardShare, RewardCurrency> {
                stake_id: self.id(),
                reward_pool_id: reward_pool.id(),
            });
        },
        _ => abort ENotLockedState,
    }
}

public fun unregister_reward_pool<RewardShare, RewardCurrency>(
    self: &mut RewardStake<RewardShare>,
    reward_pool: &mut RewardPool<RewardShare, RewardCurrency>,
) {
    match (&mut self.state) {
        RewardStakeState::Locked(registrations) => {
            let currency_type = with_defining_ids<RewardCurrency>();
            assert!(registrations.contains(&currency_type), ERewardPoolNotRegistered);

            let (_, last_claim_index) = registrations.remove(&currency_type);
            assert!(
                last_claim_index == reward_pool.cumulative_reward_per_share(),
                ELastClaimIndexMismatch,
            );

            reward_pool.decrease_staked_shares(self.balance.value());

            emit(RewardPoolUnregisteredEvent<RewardShare, RewardCurrency> {
                stake_id: self.id(),
                reward_pool_id: reward_pool.id(),
            });
        },
        _ => abort ENotLockedState,
    }
}

public fun request_share_deposit<RewardShare>(
    self: &mut RewardStake<RewardShare>,
    balance: Balance<RewardShare>,
): RewardShareDepositReceipt {
    assert!(balance.value() > 0, EZeroBalance);

    let mut pool_currency_types: VecSet<TypeName> = vec_set::empty();

    match (&self.state) {
        // If the stake is in `Locked` state, collect the currency types of the Reward pools that are registered
        // for inclusion in the share deposit receipt.
        RewardStakeState::Locked(reward_pool_registrations) => {
            reward_pool_registrations.keys().destroy!(|v| pool_currency_types.insert(v));
        },
        // If the stake is in `Unlocking` state, abort because deposits are not supported during the unlock period.
        RewardStakeState::Unlocking(_) => {
            abort EUnsupportedStateForDeposit
        },
        _ => {},
    };

    let deposit_value = balance.value();

    self.balance.join(balance);

    let receipt = RewardShareDepositReceipt {
        stake_id: self.id(),
        deposit_value,
        pool_currency_types,
    };

    receipt
}

public fun resolve_share_deposit<RewardShare, RewardCurrency>(
    self: &RewardStake<RewardShare>,
    receipt: &mut RewardShareDepositReceipt,
    reward_pool: &mut RewardPool<RewardShare, RewardCurrency>,
) {
    assert!(receipt.stake_id == self.id(), EInvalidStake);

    let currency_type = with_defining_ids<RewardCurrency>();
    assert!(
        receipt.pool_currency_types.contains(&currency_type),
        EReceiptRewardCurrencyTypeNotFound,
    );

    receipt.pool_currency_types.remove(&currency_type);
    reward_pool.increase_staked_shares(receipt.deposit_value);
}

public fun finalize_share_deposit(receipt: RewardShareDepositReceipt) {
    assert!(receipt.pool_currency_types.is_empty(), EReceiptRewardCurrencyTypesNotEmpty);
    let RewardShareDepositReceipt { stake_id, deposit_value, .. } = receipt;

    emit(RewardStakeRewardShareDepositEvent {
        stake_id,
        deposit_value,
    });
}

public fun withdraw_shares<RewardShare>(
    self: &mut RewardStake<RewardShare>,
    value: Option<u64>,
): Balance<RewardShare> {
    match (self.state) {
        RewardStakeState::Unlocked => {
            let withdraw_value = value.destroy_or!(self.balance.value());
            assert!(withdraw_value <= self.balance.value(), EWithdrawValueExceedsBalance);
            let balance = self.balance.split(withdraw_value);

            emit(RewardStakeRewardShareWithdrawalEvent {
                stake_id: self.id(),
                withdraw_value: balance.value(),
            });

            balance
        },
        _ => abort ENotUnlockedState,
    }
}

//=== Public View Functions ===

public fun id<RewardShare>(self: &RewardStake<RewardShare>): ID {
    self.id.to_inner()
}

public fun balance<RewardShare>(self: &RewardStake<RewardShare>): &Balance<RewardShare> {
    &self.balance
}

public fun is_unlocked_state<RewardShare>(self: &RewardStake<RewardShare>): bool {
    match (self.state) {
        RewardStakeState::Unlocked => true,
        _ => false,
    }
}

public fun is_locked_state<RewardShare>(self: &RewardStake<RewardShare>): bool {
    match (self.state) {
        RewardStakeState::Locked(_) => true,
        _ => false,
    }
}

public fun is_unlocking_state<RewardShare>(self: &RewardStake<RewardShare>): bool {
    match (self.state) {
        RewardStakeState::Unlocking(_) => true,
        _ => false,
    }
}

//=== Assert Functions ===

public fun assert_is_unlocked_state<RewardShare>(self: &RewardStake<RewardShare>) {
    assert!(is_unlocked_state(self), ENotUnlockedState);
}

public fun assert_is_locked_state<RewardShare>(self: &RewardStake<RewardShare>) {
    assert!(is_locked_state(self), ENotLockedState);
}

public fun assert_is_unlocking_state<RewardShare>(self: &RewardStake<RewardShare>) {
    assert!(is_unlocking_state(self), ENotUnlockingState);
}
