module reward_pool::reward_pool;

use hikida::hikida;
use stake::stake::{Self, Stake};
use std::type_name::{TypeName, with_defining_ids};
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::derived_object::{claim, derive_address};
use sui::event::emit;
use sui::transfer::Receiving;

//=== Structs ===

public struct RewardPool<phantom Share, phantom Currency> has key {
    id: UID,
    kind: RewardPoolKind,
    balance: Balance<Currency>,
    staked_shares: u64,
    cumulative_reward_per_share: u256,
    cumulative_deposits: u128,
}

/// The kind of reward pool.
///
/// Open: Any stake can register regardless of its authorities.
/// Authorized: Only stakes that carry the specified authority badge can register.
/// This allows the pool to enforce that stakes were created through a specific
/// interaction flow (e.g., burning tokens) without requiring the witness module
/// to be in the registration call path.
public enum RewardPoolKind has copy, drop, store {
    Open,
    Authorized(TypeName),
}

/// Witness type for the reward pool extension on Stakes.
/// Only this module can construct instances, providing access control
/// to the extension's isolated storage Bag.
public struct RewardPoolExtension() has drop;

/// Key used to derive a RewardPool's object ID from a parent UID, and also used
/// as the key within the extension's storage Bag on Stakes.
///
/// Fields: (Share type, Currency type, required authority type).
///
/// Uses TypeName values instead of phantom types to enable runtime address derivation
/// without requiring compile-time knowledge of all types. This is essential for
/// protocols that:
/// - Iterate over pools with heterogeneous share types in a single transaction
/// - Distribute funds to multiple pools without complex PTB orchestration
/// - Derive pool addresses using stored TypeName values
///
/// The optional authority type allows multiple pools with the same (Share, Currency)
/// pair under a single parent, differentiated by their stake authorization requirement.
///
/// Type safety is preserved at pool creation (`new<Share, Currency>` requires actual types),
/// while lookup remains flexible. An incorrect TypeName simply yields a wrong address
/// (nothing found), not a security vulnerability.
public struct RewardPoolKey(TypeName, TypeName, Option<TypeName>) has copy, drop, store;

/// Registration config stored in the extension's storage Bag on a Stake.
public struct RewardPoolRegistration has drop, store {
    pool_id: ID,
    last_claim_index: u256,
    unregister_requested_at_epoch: Option<u64>,
}

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
const ELastClaimIndexMismatch: u64 = 5;
const EPoolIdMismatch: u64 = 6;
const EUnregisterNotRequested: u64 = 7;
const EUnregisterAlreadyRequested: u64 = 8;
const EUnregisterDelayNotElapsed: u64 = 9;
const EMissingAuthority: u64 = 10;
const EInvalidValue: u64 = 11;

//=== Public Functions ===

/// Create a new reward pool as a derived object of the given parent.
///
/// The pool's object ID is deterministically derived from the parent UID, the Share and
/// Currency type parameters, and the pool's kind. This means at most one pool can exist
/// per unique (parent, Share, Currency, kind) combination.
///
/// If `kind` is `Authorized(authority_type)`, only stakes carrying that authority badge
/// can register. If `Open`, any stake can register.
public fun new<Share, Currency>(
    parent: &mut UID,
    kind: RewardPoolKind,
): RewardPool<Share, Currency> {
    let key = RewardPoolKey(
        with_defining_ids<Share>(),
        with_defining_ids<Currency>(),
        kind.authority_type(),
    );

    let reward_pool = RewardPool<Share, Currency> {
        id: claim(parent, key),
        kind,
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

/// Deposit funds into the reward pool.
public fun deposit<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    balance: Balance<Currency>,
) {
    self.deposit_impl(balance);
}

/// Register a stake with the reward pool.
///
/// Installs the `RewardPoolExtension` on the stake if not already present, then adds
/// a `RewardPoolRegistration` to the extension's storage keyed by `RewardPoolKey`.
/// If the pool is `Authorized`, the stake must carry a matching authority badge.
///
/// A stake can register with multiple reward pools — each registration is stored
/// under a different `RewardPoolKey` in the extension's inner Bag.
public fun register_stake<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    stake: &mut Stake<Share>,
    ctx: &mut TxContext,
) {
    // Read from stake before acquiring mutable storage to avoid borrow conflict
    match (&self.kind) {
        RewardPoolKind::Open => {},
        RewardPoolKind::Authorized(authority_type) => {
            assert!(stake.has_authority(authority_type), EMissingAuthority);
        },
    };

    let staked_amount = stake.balance().value();

    // Install extension if this is the stake's first reward pool registration
    if (!stake.has_extension<Share, RewardPoolExtension>()) {
        stake.add_extension(RewardPoolExtension(), ctx);
    };

    let key = self.reward_pool_key();
    let storage = stake.storage_mut(RewardPoolExtension());
    assert!(
        !storage.contains_with_type<RewardPoolKey, RewardPoolRegistration>(key),
        EAlreadyRegistered,
    );

    let registration = RewardPoolRegistration {
        pool_id: self.id(),
        last_claim_index: self.cumulative_reward_per_share,
        unregister_requested_at_epoch: option::none(),
    };

    storage.add(key, registration);
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
    let key = self.reward_pool_key();
    let storage = stake.storage_mut(RewardPoolExtension());

    let registration: &mut RewardPoolRegistration = storage.borrow_mut(key);
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
    let key = self.reward_pool_key();
    let storage = stake.storage_mut(RewardPoolExtension());

    let registration: &mut RewardPoolRegistration = storage.borrow_mut(key);
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
/// Removes the registration from the extension's storage.
public fun unregister_stake<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    stake: &mut Stake<Share>,
    ctx: &TxContext,
) {
    let key = self.reward_pool_key();
    let storage = stake.storage_mut(RewardPoolExtension());

    // Check unregister request and delay
    {
        let registration: &RewardPoolRegistration = storage.borrow(key);
        assert!(registration.pool_id == self.id(), EPoolIdMismatch);
        assert!(registration.unregister_requested_at_epoch.is_some(), EUnregisterNotRequested);

        let requested_at = *registration.unregister_requested_at_epoch.borrow();
        assert!(ctx.epoch() >= requested_at + UNREGISTER_DELAY_EPOCHS, EUnregisterDelayNotElapsed);
    };

    let registration: RewardPoolRegistration = storage.remove(key);
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
    let key = self.reward_pool_key();

    // Read balance and registration data before mutable borrow
    let staked_amount = stake.balance().value();

    let last_claim_index = {
        let storage = stake.storage(RewardPoolExtension());
        let registration: &RewardPoolRegistration = storage.borrow(key);
        assert!(registration.pool_id == self.id(), EPoolIdMismatch);
        registration.last_claim_index
    };

    let reward_amount = calculate_reward(
        staked_amount,
        last_claim_index,
        self.cumulative_reward_per_share,
    );

    // Now mutably borrow to update
    let storage = stake.storage_mut(RewardPoolExtension());
    let registration: &mut RewardPoolRegistration = storage.borrow_mut(key);
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
    if (!stake.has_extension<Share, RewardPoolExtension>()) {
        return 0
    };

    let key = self.reward_pool_key();
    let storage = stake.storage(RewardPoolExtension());

    if (!storage.contains_with_type<RewardPoolKey, RewardPoolRegistration>(key)) {
        return 0
    };

    let registration: &RewardPoolRegistration = storage.borrow(key);
    if (registration.pool_id != self.id()) {
        return 0
    };

    calculate_reward(
        stake.balance().value(),
        registration.last_claim_index,
        self.cumulative_reward_per_share,
    )
}

/// Withdraw from a reward pool.
/// Requires the parent's &mut UID to authorize the operation.
public fun withdraw<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    parent: &mut UID,
    value: Option<u64>,
): Balance<Currency> {
    self.assert_authorized(parent);

    let value = value.destroy_or!(self.balance.value());
    self.balance.split(value)
}

/// Receive coins that were sent to the reward pool's address and deposit them as rewards.
///
/// This enables a pull-based funding model: external parties send coins to the pool's
/// address, and anyone can call this to convert those pending transfers into distributed
/// rewards. Useful when the pool needs to accept payments from parties that don't have
/// direct access to a `&mut RewardPool` reference.
public fun receive_and_deposit<Share, Currency>(
    self: &mut RewardPool<Share, Currency>,
    coins_to_receive: vector<Receiving<Coin<Currency>>>,
) {
    assert!(!coins_to_receive.is_empty(), ENoCoinsToReceive);
    let balance = hikida::receive_balance(&mut self.id, coins_to_receive);
    self.deposit_impl(balance);
}

/// Redeem hikida funds held by the reward pool and deposit them as rewards.
public fun redeem_and_deposit<Share, Currency>(self: &mut RewardPool<Share, Currency>, value: u64) {
    assert!(value > 0, EInvalidValue);
    let balance = hikida::redeem_balance(&mut self.id, value);
    self.deposit_impl(balance);
}

/// Create an open reward pool kind. Any stake can register.
public fun new_open_kind(): RewardPoolKind {
    RewardPoolKind::Open
}

/// Create an authorized reward pool kind. Only stakes carrying the specified
/// authority badge can register.
public fun new_authorized_kind<Authority: drop>(_: Authority): RewardPoolKind {
    RewardPoolKind::Authorized(with_defining_ids<Authority>())
}

//=== Public View Functions ===

/// Return the reward pool's object ID.
public fun id<Share, Currency>(self: &RewardPool<Share, Currency>): ID {
    self.id.to_inner()
}

/// Compute the deterministic address of a reward pool given its parent ID and type parameters.
/// Useful for off-chain address derivation without needing a pool reference.
public fun derived_address(
    parent_id: ID,
    share_type: TypeName,
    currency_type: TypeName,
    authority_type: Option<TypeName>,
): address {
    derive_address(parent_id, RewardPoolKey(share_type, currency_type, authority_type))
}

/// Return a reference to the reward pool's balance.
public fun balance<Share, Currency>(self: &RewardPool<Share, Currency>): &Balance<Currency> {
    &self.balance
}

/// Return the reward pool's kind.
public fun kind<Share, Currency>(self: &RewardPool<Share, Currency>): &RewardPoolKind {
    &self.kind
}

/// Return the total number of staked shares in the pool.
public fun staked_shares<Share, Currency>(self: &RewardPool<Share, Currency>): u64 {
    self.staked_shares
}

/// Return the cumulative reward per share accumulator (scaled by `PRECISION`).
public fun cumulative_reward_per_share<Share, Currency>(self: &RewardPool<Share, Currency>): u256 {
    self.cumulative_reward_per_share
}

/// Return the total amount ever deposited into the pool.
public fun cumulative_deposits<Share, Currency>(self: &RewardPool<Share, Currency>): u128 {
    self.cumulative_deposits
}

/// Return the authority type for an authorized pool, or `none` for an open pool.
public fun authority_type(self: &RewardPoolKind): Option<TypeName> {
    match (self) {
        RewardPoolKind::Open => option::none(),
        RewardPoolKind::Authorized(authority_type) => option::some(*authority_type),
    }
}

/// Asserts that the reward pool was derived from the given parent UID.
///
/// Requires `&mut UID` rather than `&UID` for security: many objects expose ungated `&UID`
/// accessors for identification purposes. If this function accepted `&UID`, a malicious package
/// could use that ungated access to pass authorization checks for privileged operations like
/// `withdraw`. Requiring `&mut UID` ensures only code with administrative access to the parent
/// can authorize operations on the pool.
#[allow(unused_mut_parameter)]
public fun assert_authorized<Share, Currency>(
    self: &RewardPool<Share, Currency>,
    parent: &mut UID,
) {
    assert!(
        self.id.to_address() == derive_address(parent.to_inner(), self.reward_pool_key()),
        EUnauthorized,
    );
}

/// Assert that the reward pool was derived from the given parent ID.
///
/// Unlike `assert_authorized`, this accepts an `ID` rather than `&mut UID` and therefore
/// does not serve as an access control gate. Use this for read-only verification where
/// proving the parent-child relationship is sufficient (e.g., view functions or
/// cross-module validations that don't perform privileged mutations).
public fun assert_derived_from<Share, Currency>(self: &RewardPool<Share, Currency>, parent_id: ID) {
    assert!(
        self.id.to_address() == derive_address(parent_id, self.reward_pool_key()),
        EUnauthorized,
    );
}

//=== Private Functions ===

/// Build the derivation key for this reward pool.
/// Also used as the key within the extension's storage Bag on stakes.
fun reward_pool_key<Share, Currency>(self: &RewardPool<Share, Currency>): RewardPoolKey {
    RewardPoolKey(
        with_defining_ids<Share>(),
        with_defining_ids<Currency>(),
        self.kind.authority_type(),
    )
}

/// Increase the pool's staked share count and emit an event.
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

/// Decrease the pool's staked share count and emit an event.
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

/// Calculate the reward owed for a given staked amount based on the difference between
/// the current cumulative index and the stake's last claim index.
fun calculate_reward(staked_amount: u64, last_claim_index: u256, current_index: u256): u64 {
    let reward_delta = current_index - last_claim_index;
    let reward = (staked_amount as u256) * reward_delta / PRECISION;
    (reward as u64)
}
