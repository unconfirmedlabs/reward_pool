module reward_pool::reward_pool;

use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::derived_object::{claim, derive_address};
use sui::event::emit;
use sui::transfer::Receiving;

//=== Structs ===

public struct RewardPool<phantom PoolShare, phantom RewardCurrency> has key, store {
    id: UID,
    balance: Balance<RewardCurrency>,
    staked_shares: u64,
    cumulative_reward_per_share: u256,
    cumulative_deposits: u128,
}

public struct RewardPoolCreatedEvent<phantom PoolShare, phantom RewardCurrency> has copy, drop {
    reward_pool_id: ID,
}

public struct RewardDepositedEvent<phantom RewardCurrency> has copy, drop {
    reward_pool_id: ID,
    value: u64,
}

public struct RewardPoolStakedSharesIncreasedEvent<
    phantom PoolShare,
    phantom RewardCurrency,
> has copy, drop {
    reward_pool_id: ID,
    previous_staked_shares: u64,
    new_staked_shares: u64,
}

public struct RewardPoolStakedSharesDecreasedEvent<
    phantom PoolShare,
    phantom RewardCurrency,
> has copy, drop {
    reward_pool_id: ID,
    previous_staked_shares: u64,
    new_staked_shares: u64,
}

//=== Constants ===

const PRECISION: u256 = 1_000_000_000_000_000_000;

//=== Errors ===

const ENoStakedPoolShares: u64 = 0;
const ENoCoinsToReceive: u64 = 1;

//=== Public Functions ===

public fun new<RewardCurrency, PoolShare>(
    ctx: &mut TxContext,
): RewardPool<RewardCurrency, PoolShare> {
    let reward_pool = RewardPool<RewardCurrency, PoolShare> {
        id: object::new(ctx),
        balance: balance::zero(),
        staked_shares: 0,
        cumulative_reward_per_share: 0,
        cumulative_deposits: 0,
    };

    emit(RewardPoolCreatedEvent<RewardCurrency, PoolShare> {
        reward_pool_id: reward_pool.id(),
    });

    reward_pool
}

public fun new_derived<RewardCurrency, PoolShare, Key: copy + drop + store>(
    parent: &mut UID,
    key: Key,
): RewardPool<RewardCurrency, PoolShare> {
    let reward_pool = RewardPool<RewardCurrency, PoolShare> {
        id: claim(parent, key),
        balance: balance::zero(),
        staked_shares: 0,
        cumulative_reward_per_share: 0,
        cumulative_deposits: 0,
    };

    emit(RewardPoolCreatedEvent<RewardCurrency, PoolShare> {
        reward_pool_id: reward_pool.id(),
    });

    reward_pool
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

//=== Package Functions ===

public(package) fun increase_staked_shares<PoolShare, RewardCurrency>(
    self: &mut RewardPool<PoolShare, RewardCurrency>,
    value: u64,
) {
    let previous_staked_shares = self.staked_shares;
    let new_staked_shares = previous_staked_shares + value;

    self.staked_shares = new_staked_shares;

    emit(RewardPoolStakedSharesIncreasedEvent<PoolShare, RewardCurrency> {
        reward_pool_id: self.id(),
        previous_staked_shares,
        new_staked_shares,
    });
}

public(package) fun decrease_staked_shares<PoolShare, RewardCurrency>(
    self: &mut RewardPool<PoolShare, RewardCurrency>,
    value: u64,
) {
    let previous_staked_shares = self.staked_shares;
    let new_staked_shares = previous_staked_shares - value;

    self.staked_shares = self.staked_shares - value;

    emit(RewardPoolStakedSharesDecreasedEvent<PoolShare, RewardCurrency> {
        reward_pool_id: self.id(),
        previous_staked_shares,
        new_staked_shares,
    });
}

public(package) fun uid_mut<PoolShare, RewardCurrency>(
    self: &mut RewardPool<PoolShare, RewardCurrency>,
): &mut UID {
    &mut self.id
}

//=== Public View Functions ===

public fun id<PoolShare, RewardCurrency>(self: &RewardPool<PoolShare, RewardCurrency>): ID {
    self.id.to_inner()
}

public fun balance<PoolShare, RewardCurrency>(
    self: &RewardPool<PoolShare, RewardCurrency>,
): &Balance<RewardCurrency> {
    &self.balance
}

public fun staked_shares<PoolShare, RewardCurrency>(
    self: &RewardPool<PoolShare, RewardCurrency>,
): u64 {
    self.staked_shares
}

public fun cumulative_reward_per_share<PoolShare, RewardCurrency>(
    self: &RewardPool<PoolShare, RewardCurrency>,
): u256 {
    self.cumulative_reward_per_share
}

public fun cumulative_deposits<PoolShare, RewardCurrency>(
    self: &RewardPool<PoolShare, RewardCurrency>,
): u128 {
    self.cumulative_deposits
}

public fun derived_address<Key: copy + drop + store>(parent_id: ID, key: Key): address {
    derive_address(parent_id, key)
}

//=== Private Functions ===

fun deposit_impl<PoolShare, RewardCurrency>(
    self: &mut RewardPool<PoolShare, RewardCurrency>,
    balance: Balance<RewardCurrency>,
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
    //    This ensures no royalties are lost due to timing mismatches between when payments
    //    arrive and when shareholders register their entitlements.
    //
    // Callers should check staked_shares > 0 before sending transactions, or expect
    // this to revert if no shareholders have staked yet.
    assert!(self.staked_shares > 0, ENoStakedPoolShares);

    let deposit_value = balance.value();

    let reward_per_share = (deposit_value as u256) * PRECISION / (self.staked_shares as u256);
    self.cumulative_reward_per_share = self.cumulative_reward_per_share + reward_per_share;
    self.cumulative_deposits = self.cumulative_deposits + (deposit_value as u128);

    self.balance.join(balance);

    emit(RewardDepositedEvent<RewardCurrency> {
        reward_pool_id: self.id(),
        value: deposit_value,
    });
}
