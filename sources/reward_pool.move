module reward_pool::reward_pool;

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

public struct RewardPoolStakedSharesIncreasedEvent<
    phantom Share,
    phantom Currency,
> has copy, drop {
    reward_pool_id: ID,
    previous_staked_shares: u64,
    new_staked_shares: u64,
}

public struct RewardPoolStakedSharesDecreasedEvent<
    phantom Share,
    phantom Currency,
> has copy, drop {
    reward_pool_id: ID,
    previous_staked_shares: u64,
    new_staked_shares: u64,
}

//=== Constants ===

const PRECISION: u256 = 1_000_000_000_000_000_000;

//=== Errors ===

const EUnauthorized: u64 = 0;
const ENoStakedShares: u64 = 1;
const ENoCoinsToReceive: u64 = 2;

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

public fun redeem_and_deposit<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    value: u64,
) {
    let withdrawal = withdraw_funds_from_object(&mut self.id, value);
    let balance = redeem_funds(withdrawal);
    self.deposit_impl(balance);
}

// Withdraw from a reward pool.
// Requires the parent's &mut UID to authorize the operation.
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

//=== Package Functions ===

public(package) fun increase_staked_shares<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    value: u64,
) {
    let previous_staked_shares = self.staked_shares;
    let new_staked_shares = previous_staked_shares + value;

    self.staked_shares = new_staked_shares;

    emit(RewardPoolStakedSharesIncreasedEvent<Share, Currency> {
        reward_pool_id: self.id(),
        previous_staked_shares,
        new_staked_shares,
    });
}

public(package) fun decrease_staked_shares<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    value: u64,
) {
    let previous_staked_shares = self.staked_shares;
    let new_staked_shares = previous_staked_shares - value;

    self.staked_shares = new_staked_shares;

    emit(RewardPoolStakedSharesDecreasedEvent<Share, Currency> {
        reward_pool_id: self.id(),
        previous_staked_shares,
        new_staked_shares,
    });
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

public fun cumulative_reward_per_share<Share, Currency>(
    self: &RewardPool<Share, Currency>,
): u256 {
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

public fun assert_derived_from<Share, Currency>(
    self: &RewardPool<Share, Currency>,
    parent_id: ID,
) {
    assert!(
        self.id.to_address() == derive_address(parent_id, RewardPoolKey(with_defining_ids<Share>(), with_defining_ids<Currency>())),
        EUnauthorized,
    );
}

//=== Private Functions ===

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
