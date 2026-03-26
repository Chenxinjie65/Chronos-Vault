# Chronos Vault

Chronos Vault is a single-asset staking protocol with fixed lock tiers, early-exit penalties, and penalty redistribution to remaining stakers.

This project is intentionally scoped to be small-to-medium size and self-contained, so an AI coding agent can build it end-to-end without relying on external DeFi protocols.

## Goal

Build a minimal but production-structured smart contract project that allows:

- users to stake one ERC20 asset
- users to choose a fixed lock tier when staking
- users to earn rewards over time from an admin-funded reward pool
- users who exit before lock expiry to pay a penalty
- penalties to be redistributed to remaining stakers
- safe accounting with clear invariants and tests

## Non-goals

This project does NOT include:

- external strategies
- lending / borrowing
- AMM logic
- external oracle integrations
- upgradeability
- governance
- multi-token reward systems
- multiple stake assets
- rebasing tokens support
- fee-on-transfer token support

## Core idea

Users deposit a single staking token into the vault.

Each stake position has:
- owner
- amount
- lock duration
- unlock timestamp
- reward debt / accounting fields
- status

Rewards come from two internal sources:
1. admin-funded rewards
2. penalties collected from users who withdraw early

Remaining stakers benefit from those penalties indirectly through the protocol reward accounting.

## Suggested architecture

- `src/ChronosVault.sol`
  - main staking contract
  - stake / unstake / claim / accounting
- `src/interfaces/IChronosVault.sol`
  - external API and NatSpec reference for integrations
- `src/MockERC20.sol`
  - staking token used in tests
- `src/libraries/`
  - optional math or position helper libraries
- `test/`
  - unit + integration-style tests
- `script/`
  - deployment script(s)

## Recommended stack

- Solidity `^0.8.24`
- Foundry
- OpenZeppelin ERC20 / SafeERC20 / Ownable / Pausable / ReentrancyGuard

## MVP features

- stake tokens into the vault
- choose lock tier at stake time
- claim rewards
- unstake after lock expiry with no penalty
- unstake before lock expiry with penalty
- collected penalty redistributed to remaining stakers
- admin can fund reward pool
- pause / unpause
- emergency withdrawal mode

## Lock tiers

Use fixed lock tiers rather than arbitrary user-provided durations.

Suggested tiers:
- 30 days
- 90 days
- 180 days

Suggested reward weights:
- 1.0x for 30d
- 1.5x for 90d
- 2.0x for 180d

These weights are used only for reward distribution, not for principal accounting.

## High-level accounting model

Use a weighted-share system:
- principal is the real deposited token amount
- reward power is based on `amount * weight`

Rewards are distributed using a standard accumulated reward-per-share model over weighted stake units.

Penalty redistribution should increase the reward pool for remaining users.

If rewards, penalties, or forfeited rewards arise while no active weighted stake exists, that value is routed to `treasury` instead of being stored for later user capture.

## Example user flow

1. Admin deploys staking token and vault.
2. Admin funds reward pool with reward tokens.
3. Alice stakes 100 tokens at 90d lock.
4. Bob stakes 100 tokens at 30d lock.
5. Alice and Bob accrue rewards based on weighted stake units.
6. Bob exits early before 30d expiry and pays a penalty.
7. That penalty is added into protocol-distributed rewards.
8. Alice remains staked and benefits from the redistributed penalty.
9. Alice later claims rewards and/or withdraws after lock expiry.

## Security expectations

The implementation must pay attention to:
- reward accounting correctness
- avoiding double-claim or double-withdraw
- reentrancy-safe token flow
- proper use of checks-effects-interactions
- pause behavior
- clear emergency mode semantics
- avoiding silent token loss
- preventing stale accounting bugs

## Interface and integration notes

The recommended integration target is `IChronosVault`, not the concrete implementation ABI.

Useful read paths:
- `getUserPositionIds(user)`
- `getUserActivePositionIds(user)`
- `getPosition(positionId)`
- `getLockTier(tierId)`
- `getAllLockTierIds()`
- `pendingRewards(positionId)`
- `previewWithdraw(positionId)`

Write paths:
- `stake`
- `claim`
- `claimBatch`
- `withdraw`
- `emergencyWithdraw`

`previewWithdraw(positionId)` semantics:
- missing or withdrawn positions return `(0, 0, 0)`
- normal mode returns the current principal/reward/penalty outcome
- emergency mode previews the emergency path only: principal only, zero reward, zero penalty

## Acceptance expectations

A successful implementation should include:
- clean contract structure
- clear comments on accounting logic
- comprehensive tests
- invariant-minded reasoning
- minimal and reviewable code
- no unnecessary abstraction

## Local development

This repository uses the standard Foundry layout with `src/` as the main source directory.

### Prerequisites

- Foundry (`forge`, `cast`, `anvil`)

### Install dependencies

Clone with submodules:

```bash
git clone --recurse-submodules <repo-url>
```

If already cloned without submodules:

```bash
git submodule update --init --recursive
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Format

```bash
forge fmt
```

### Deploy

Deploy a mock token and vault:

```bash
TREASURY=0x000000000000000000000000000000000000bEEF \
forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript --sig "run()"
```

Deploy a vault using an existing staking token:

```bash
TREASURY=0x000000000000000000000000000000000000bEEF \
EXISTING_TOKEN=0x000000000000000000000000000000000000c0Fe \
forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript --sig "run()"
```

## Operations notes

Pause mode:
- disables `stake`
- disables `claim` and `claimBatch`
- disables early `withdraw`
- still allows matured `withdraw`
- only allows `emergencyWithdraw` if emergency mode has already been enabled

Emergency mode:
- is irreversible for this MVP
- disables `claim` and `claimBatch`
- normal `withdraw` is not available
- users can recover principal with `emergencyWithdraw`
- pending rewards from emergency-withdrawn positions are redistributed to active stakers, or routed to treasury if none remain

## Current status

The repository currently includes:
- fixed lock tiers: 30d / 90d / 180d
- multiple positions per user
- admin-funded same-token rewards
- early withdraw penalties with redistribution
- zero-staker treasury routing
- pause / emergency mode controls
- view helpers for positions and tiers
- batch reward claiming
- Foundry deployment script
- a passing Foundry test suite covering user flows, admin paths, time edges, and helper views
