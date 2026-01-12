module royalty_pool::royalty_stake;

use royalty_pool::royalty_pool::RoyaltyPool;
use std::type_name::{TypeName, with_defining_ids};
use sui::balance::{Self, Balance};
use sui::event::emit;
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

//=== Structs ===

public struct RoyaltyStake<phantom Share> has key, store {
    id: UID,
    state: RoyaltyStakeState,
    balance: Balance<Share>,
}

public enum RoyaltyStakeState has copy, drop, store {
    Unlocked,
    Locked(VecMap<TypeName, u256>), // claim index by currency type
    Unlocking(u64), // unlock epoch
}

public struct ShareDepositReceipt {
    stake_id: ID,
    deposit_value: u64,
    pool_currency_types: VecSet<TypeName>,
}

//=== Events ===

public struct RoyaltyStakeCreatedEvent has copy, drop {
    stake_id: ID,
}

public struct RoyaltyStakeLockedEvent has copy, drop {
    stake_id: ID,
}

public struct RoyaltyStakeLockRequestedEvent has copy, drop {
    stake_id: ID,
    unlock_epoch: u64,
}

public struct RoyaltyStakeUnlockedEvent has copy, drop {
    stake_id: ID,
}

public struct RoyaltyStakeUnlockCanceledEvent has copy, drop {
    stake_id: ID,
}

public struct RoyaltyStakeShareDepositEvent has copy, drop {
    stake_id: ID,
    deposit_value: u64,
}

public struct RoyaltyStakeShareWithdrawalEvent has copy, drop {
    stake_id: ID,
    withdraw_value: u64,
}

public struct RoyaltyPoolRegisteredEvent<phantom Share, phantom Currency> has copy, drop {
    stake_id: ID,
    royalty_pool_id: ID,
}

public struct RoyaltyPoolUnregisteredEvent<phantom Share, phantom Currency> has copy, drop {
    stake_id: ID,
    royalty_pool_id: ID,
}

//=== Constants ===

const UNLOCK_DELAY_EPOCHS: u64 = 2;

//=== Errors ===

const ENotUnlockedState: u64 = 0;
const ENotUnlockingState: u64 = 1;
const ENotLockedState: u64 = 2;
const EUnlockEpochNotReached: u64 = 3;
const EWithdrawValueExceedsBalance: u64 = 4;
const ERoyaltyPoolAlreadyRegistered: u64 = 5;
const ERoyaltyPoolNotRegistered: u64 = 6;
const ERegistrationsNotEmpty: u64 = 7;
const ELastClaimIndexMismatch: u64 = 8;
const EInvalidStake: u64 = 9;
const EReceiptCurrencyTypeNotFound: u64 = 10;
const EReceiptCurrencyTypesNotEmpty: u64 = 11;
const EUnsupportedStateForDeposit: u64 = 12;
const EZeroBalance: u64 = 13;

//=== Public Functions ===

public fun new<Share>(ctx: &mut TxContext): RoyaltyStake<Share> {
    let stake = RoyaltyStake {
        id: object::new(ctx),
        state: RoyaltyStakeState::Unlocked,
        balance: balance::zero(),
    };

    emit(RoyaltyStakeCreatedEvent {
        stake_id: stake.id(),
    });

    stake
}

public fun lock<Share>(self: &mut RoyaltyStake<Share>) {
    match (self.state) {
        RoyaltyStakeState::Unlocked => {
            self.state = RoyaltyStakeState::Locked(vec_map::empty());

            emit(RoyaltyStakeLockedEvent {
                stake_id: self.id(),
            });
        },
        _ => abort ENotUnlockedState,
    }
}

public fun request_unlock<Share>(self: &mut RoyaltyStake<Share>, ctx: &TxContext) {
    match (self.state) {
        RoyaltyStakeState::Locked(royalty_pool_registrations) => {
            assert!(royalty_pool_registrations.is_empty(), ERegistrationsNotEmpty);

            let unlock_epoch = ctx.epoch() + UNLOCK_DELAY_EPOCHS;
            self.state = RoyaltyStakeState::Unlocking(unlock_epoch);

            emit(RoyaltyStakeLockRequestedEvent {
                stake_id: self.id(),
                unlock_epoch,
            });
        },
        _ => abort ENotLockedState,
    }
}

public fun unlock<Share>(self: &mut RoyaltyStake<Share>, ctx: &TxContext) {
    match (self.state) {
        RoyaltyStakeState::Unlocking(unlock_epoch) => {
            assert!(ctx.epoch() >= unlock_epoch, EUnlockEpochNotReached);
            self.state = RoyaltyStakeState::Unlocked;

            emit(RoyaltyStakeUnlockedEvent {
                stake_id: self.id(),
            });
        },
        _ => abort ENotUnlockingState,
    }
}

public fun cancel_unlock<Share>(self: &mut RoyaltyStake<Share>) {
    match (self.state) {
        RoyaltyStakeState::Unlocking(_) => {
            self.state = RoyaltyStakeState::Locked(vec_map::empty());

            emit(RoyaltyStakeUnlockCanceledEvent {
                stake_id: self.id(),
            });
        },
        _ => abort ENotUnlockingState,
    }
}

public fun register_royalty_pool<Share, Currency>(
    self: &mut RoyaltyStake<Share>,
    royalty_pool: &mut RoyaltyPool<Share, Currency>,
) {
    match (&mut self.state) {
        RoyaltyStakeState::Locked(registrations) => {
            let currency_type = with_defining_ids<Currency>();
            assert!(!registrations.contains(&currency_type), ERoyaltyPoolAlreadyRegistered);
            registrations.insert(currency_type, royalty_pool.cumulative_royalty_per_share());
            royalty_pool.increase_staked_shares(self.balance.value());

            emit(RoyaltyPoolRegisteredEvent<Share, Currency> {
                stake_id: self.id(),
                royalty_pool_id: royalty_pool.id(),
            });
        },
        _ => abort ENotLockedState,
    }
}

public fun unregister_royalty_pool<Share, Currency>(
    self: &mut RoyaltyStake<Share>,
    royalty_pool: &mut RoyaltyPool<Share, Currency>,
) {
    match (&mut self.state) {
        RoyaltyStakeState::Locked(registrations) => {
            let currency_type = with_defining_ids<Currency>();
            assert!(registrations.contains(&currency_type), ERoyaltyPoolNotRegistered);

            let (_, last_claim_index) = registrations.remove(&currency_type);
            assert!(
                last_claim_index == royalty_pool.cumulative_royalty_per_share(),
                ELastClaimIndexMismatch,
            );

            royalty_pool.decrease_staked_shares(self.balance.value());

            emit(RoyaltyPoolUnregisteredEvent<Share, Currency> {
                stake_id: self.id(),
                royalty_pool_id: royalty_pool.id(),
            });
        },
        _ => abort ENotLockedState,
    }
}

public fun request_share_deposit<Share>(
    self: &mut RoyaltyStake<Share>,
    balance: Balance<Share>,
): ShareDepositReceipt {
    assert!(balance.value() > 0, EZeroBalance);

    let mut pool_currency_types: VecSet<TypeName> = vec_set::empty();

    match (&self.state) {
        // If the stake is in `Locked` state, collect the currency types of the Royalty pools that are registered
        // for inclusion in the share deposit receipt.
        RoyaltyStakeState::Locked(royalty_pool_registrations) => {
            royalty_pool_registrations.keys().destroy!(|v| pool_currency_types.insert(v));
        },
        // If the stake is in `Unlocking` state, abort because deposits are not supported during the unlock period.
        RoyaltyStakeState::Unlocking(_) => {
            abort EUnsupportedStateForDeposit
        },
        _ => {},
    };

    let deposit_value = balance.value();

    self.balance.join(balance);

    let receipt = ShareDepositReceipt {
        stake_id: self.id(),
        deposit_value,
        pool_currency_types,
    };

    receipt
}

public fun resolve_share_deposit<Share, Currency>(
    self: &RoyaltyStake<Share>,
    receipt: &mut ShareDepositReceipt,
    royalty_pool: &mut RoyaltyPool<Share, Currency>,
) {
    assert!(receipt.stake_id == self.id(), EInvalidStake);

    let currency_type = with_defining_ids<Currency>();
    assert!(receipt.pool_currency_types.contains(&currency_type), EReceiptCurrencyTypeNotFound);

    receipt.pool_currency_types.remove(&currency_type);
    royalty_pool.increase_staked_shares(receipt.deposit_value);
}

public fun finalize_share_deposit(receipt: ShareDepositReceipt) {
    assert!(receipt.pool_currency_types.is_empty(), EReceiptCurrencyTypesNotEmpty);
    let ShareDepositReceipt { stake_id, deposit_value, .. } = receipt;

    emit(RoyaltyStakeShareDepositEvent {
        stake_id,
        deposit_value,
    });
}

public fun withdraw_shares<Share>(
    self: &mut RoyaltyStake<Share>,
    value: Option<u64>,
): Balance<Share> {
    match (self.state) {
        RoyaltyStakeState::Unlocked => {
            let withdraw_value = value.destroy_or!(self.balance.value());
            assert!(withdraw_value <= self.balance.value(), EWithdrawValueExceedsBalance);
            let balance = self.balance.split(withdraw_value);

            emit(RoyaltyStakeShareWithdrawalEvent {
                stake_id: self.id(),
                withdraw_value: balance.value(),
            });

            balance
        },
        _ => abort ENotUnlockedState,
    }
}

//=== Public View Functions ===

public fun id<Share>(self: &RoyaltyStake<Share>): ID {
    self.id.to_inner()
}

public fun balance<Share>(self: &RoyaltyStake<Share>): &Balance<Share> {
    &self.balance
}

public fun is_unlocked_state<Share>(self: &RoyaltyStake<Share>): bool {
    match (self.state) {
        RoyaltyStakeState::Unlocked => true,
        _ => false,
    }
}

public fun is_locked_state<Share>(self: &RoyaltyStake<Share>): bool {
    match (self.state) {
        RoyaltyStakeState::Locked(_) => true,
        _ => false,
    }
}

public fun is_unlocking_state<Share>(self: &RoyaltyStake<Share>): bool {
    match (self.state) {
        RoyaltyStakeState::Unlocking(_) => true,
        _ => false,
    }
}

//=== Assert Functions ===

public fun assert_is_unlocked_state<Share>(self: &RoyaltyStake<Share>) {
    assert!(is_unlocked_state(self), ENotUnlockedState);
}

public fun assert_is_locked_state<Share>(self: &RoyaltyStake<Share>) {
    assert!(is_locked_state(self), ENotLockedState);
}

public fun assert_is_unlocking_state<Share>(self: &RoyaltyStake<Share>) {
    assert!(is_unlocking_state(self), ENotUnlockingState);
}
