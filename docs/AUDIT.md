# Audit Notes

This document is the audit-facing summary for Chronos Vault. It is intended to make review scope, trust assumptions, and critical behaviors explicit before a security review.

## In-scope contracts

Primary review target:

- [`src/ChronosVault.sol`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol)

Supporting interface:

- [`src/interfaces/IChronosVault.sol`](/home/cheng/Portfolio/Chronos-Vault/src/interfaces/IChronosVault.sol)

Auxiliary local-only contract:

- [`src/MockERC20.sol`](/home/cheng/Portfolio/Chronos-Vault/src/MockERC20.sol)

Notes:

- `MockERC20` is only for tests and local deployment flows
- the production logic is intentionally concentrated in `ChronosVault`
- there is no proxy, upgradeability layer, external strategy, or off-chain keeper dependency

## Roles and privileges

### Owner powers

The owner can:

- fund rewards via `fundRewards`
- pause and unpause the vault
- update `earlyExitPenaltyBps`, capped by `MAX_EARLY_EXIT_PENALTY_BPS`
- update `treasury`
- update the configuration of the fixed lock tiers `0`, `1`, and `2`
- enable irreversible `emergencyMode`

### User powers

Users can:

- stake into one of the fixed lock tiers
- claim rewards per position
- batch claim rewards across multiple positions
- withdraw normally after maturity
- withdraw early before maturity and pay the configured penalty
- recover principal with `emergencyWithdraw` after emergency mode is enabled

## Trust assumptions

The current MVP assumes:

- the owner is trusted for operational controls and parameter updates
- the treasury is a trusted sink for zero-staker routed value
- the staking token is a standard ERC20 without fee-on-transfer, rebasing, or callback-driven behavior
- the staking token and reward token are the same asset
- lock tiers are fixed to ids `0`, `1`, and `2`

The current implementation does not attempt to support:

- fee-on-transfer tokens
- rebasing tokens
- ERC777-style hook behavior
- partial withdrawals
- multiple reward tokens

## Critical security properties

The intended protocol properties are:

- rewards are distributed by weighted stake, not raw principal
- an early exiter must not share in the penalty they pay
- forfeited rewards from emergency exits must not remain stranded
- rewards, penalties, and forfeited rewards arising with zero active stake must route to `treasury`
- withdrawn positions are terminal and must not accrue or claim again
- paused mode must still allow mature withdrawals
- emergency mode must return principal only and remain irreversible for this MVP

## Testing posture

The repository now includes:

- unit and scenario tests in [`test/ChronosVault.t.sol`](/home/cheng/Portfolio/Chronos-Vault/test/ChronosVault.t.sol)
- fuzz tests in [`test/ChronosVaultFuzz.t.sol`](/home/cheng/Portfolio/Chronos-Vault/test/ChronosVaultFuzz.t.sol)
- invariant tests in [`test/ChronosVaultInvariants.t.sol`](/home/cheng/Portfolio/Chronos-Vault/test/ChronosVaultInvariants.t.sol)

Property-style coverage focuses on:

- zero-staker routing
- preview-to-payout consistency
- withdrawn-position terminal behavior
- total principal / weighted accounting consistency
- principal coverage of the vault balance

## Suggested audit focus

The highest-value review areas are:

- reward accumulator correctness across mixed tiers and repeated funding
- ordering of state updates during early withdraw and emergency withdraw
- zero-staker routing behavior for all value-entry paths
- owner-controlled configuration boundaries
- accounting behavior under repeated claims, repeated exits, and historical position reads

## Explicit non-goals

This MVP intentionally excludes:

- upgradeability
- governance
- external yield strategies
- ERC4626 wrappers
- NFT positions
- partial withdrawals
- referral systems
- multicall abstractions
