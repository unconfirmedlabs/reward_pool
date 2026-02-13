# Reward Pool

Accumulator-based reward distribution for staked positions on Sui.

## Overview

Reward Pool distributes fungible rewards proportionally to staked positions. It builds on [Stake](https://github.com/AftermathFinance/stake) as its extension system, using Stake's isolated Bag storage to track per-position registration state.

Each pool is a **derived object** — its address is deterministically computed from a parent UID and a triple of type parameters (Share, Currency, Authority). This enables off-chain address derivation and guarantees at most one pool per unique combination under a given parent.

## Extension Architecture

### Why Derived Objects

Reward pools are child objects of a parent (e.g., a MusicOS Composition or Recording). The parent-child relationship is enforced via address derivation rather than capability tokens:

```
pool_address = derive(parent_id, RewardPoolKey(Share, Currency, Authority))
```

This has two advantages over capability-based authorization:

1. **Deterministic discovery**: Any client can compute a pool's address from the parent's ID and the type parameters, without querying on-chain state.
2. **No capability proliferation**: The parent's `&mut UID` serves as the authorization token for privileged operations (like `withdraw`). No additional caps are minted or transferred.

The `assert_authorized` function requires `&mut UID` rather than `&UID` because many objects expose ungated `&UID` accessors for identification. Accepting `&UID` would allow any module that reads the parent for display purposes to pass authorization checks for privileged operations like withdrawal.

### Why Stake's Bag Model

Reward Pool stores per-position registration state (`RewardPoolRegistration`) inside Stake's extension Bag. This means:

- A single stake can register with multiple pools — each registration is a separate entry in the Bag, keyed by `RewardPoolKey`.
- The Reward Pool module is the only code that can read or write these registrations (via the `RewardPoolExtension` witness).
- The stake owner cannot force-remove registrations, preventing flash-unstake attacks where someone registers, claims, and immediately withdraws.

### Why TypeName-Based Keys

`RewardPoolKey` stores `TypeName` values rather than using phantom type parameters:

```move
public struct RewardPoolKey(TypeName, TypeName, Option<TypeName>) has copy, drop, store;
```

This enables runtime address derivation without compile-time knowledge of all types — essential for protocols that distribute funds to multiple pools with heterogeneous share types in a single transaction. An incorrect `TypeName` simply yields a wrong derived address (nothing found), not a security vulnerability, because type safety is enforced at pool creation time.

### Authorization Layers

The reward pool uses a layered authorization model:

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| **Ownership** | `&mut Stake<Share>` | Only the stake owner can register/claim/unregister |
| **Witness** | `RewardPoolExtension()` | Only this module can access registration data in Stake's Bag |
| **Authority badges** | `Stake.authorities: VecSet<TypeName>` | Authorized pools require stakes to carry a specific badge (e.g., proving tokens were burned) |
| **Derived object** | `assert_authorized(&mut UID)` | Only the parent admin can perform privileged operations |
| **Unregister delay** | 2-epoch waiting period | Prevents flash-unstake MEV |

## Reward Accumulator

The pool uses a standard per-share accumulator (similar to Synthetix `StakingRewards` or SushiSwap `MasterChef`):

```
On deposit:  cumulative_reward_per_share += deposit_value * PRECISION / staked_shares
On claim:    reward = staked_amount * (current_index - last_claim_index) / PRECISION
```

This provides O(1) reward calculation regardless of the number of stakers. `PRECISION = 10^18` minimizes truncation loss.

## API Reference

### Core Functions

| Function | Description |
|----------|-------------|
| `new<Share, Currency>(parent, kind)` | Create a derived reward pool |
| `share(pool)` | Share the pool object |
| `deposit(pool, balance)` | Deposit rewards into the pool |
| `register_stake(pool, stake, ctx)` | Register a stake with the pool |
| `claim_rewards(pool, stake)` | Claim accumulated rewards |
| `request_unregister_stake(pool, stake, ctx)` | Start unregister delay |
| `cancel_unregister_stake(pool, stake)` | Cancel pending unregister |
| `unregister_stake(pool, stake, ctx)` | Complete unregistration after delay |
| `withdraw(pool, parent, value)` | Withdraw funds (requires parent authorization) |

### Funding Functions

| Function | Description |
|----------|-------------|
| `receive_and_deposit(pool, coins)` | Receive coins sent to pool address and deposit as rewards |
| `redeem_and_deposit(pool, value)` | Redeem from fund accumulator and deposit as rewards |

### View Functions

| Function | Description |
|----------|-------------|
| `pending_rewards(pool, stake)` | Calculate pending rewards without claiming |
| `derived_address(parent_id, share, currency, authority)` | Compute pool address off-chain |
| `staked_shares(pool)` | Total staked amount |
| `cumulative_reward_per_share(pool)` | Current accumulator index |

## License

Apache-2.0
