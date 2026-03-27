# Chronos Vault Audit Report

## Overview

- Audit date: 2026-03-27
- Target: `ChronosVault` MVP
- Primary scope:
  - `src/ChronosVault.sol`
  - `script/DeployChronosVault.s.sol`
- Methodology: manual code review, rule-based validation, cross-checking with 8 parallel Solidity audit agents, and local `forge` verification

## Executive Summary

This review confirmed 2 issues:

- 1 High severity issue
- 1 Medium severity issue

Several additional items were recorded as compatibility risks or design observations and were not counted as formal vulnerabilities.

## Severity Summary

| Severity | Count |
| --- | ---: |
| High | 1 |
| Medium | 1 |
| Low | 0 |
| Informational | 0 |

## Findings

### [High] An early exiter can recapture its own penalty through a sibling position

- Affected code: `src/ChronosVault.sol:277-289`
- Related spec requirement: `SPEC.md:114-130`

#### Description

In the early-withdraw path, `withdraw()` removes only the exiting position's `weightedAmount` from `totalWeightedStaked` and then redistributes the penalty through `_routeOrDistributeValue()`.

That prevents the exiting position itself from sharing in the penalty, but it does not prevent the same user from receiving the redistributed penalty through another active position owned by the same address.

This directly violates the specification requirement that `the exiting user must not receive any share of the penalty they pay`.

#### Impact

- The early-exit penalty can be neutralized by a user with multiple positions.
- Penalty value intended for remaining stakers can be redirected back to the exiting user.
- A core economic constraint of the protocol is broken in a scenario that is explicitly supported by the product design: multiple positions per user.

#### Exploit Path

1. A user opens a small position `B` and keeps it active.
2. The same user opens a larger position `A`.
3. Before `A` matures, the user calls `withdraw(A)`.
4. The contract removes only `A`'s weight, then redistributes the penalty across remaining active weight.
5. Position `B`, which is still owned by the same user, receives the redistributed penalty as additional reward entitlement.
6. The user later recovers that value through `claim(B)` or `withdraw(B)`.

#### Recommendation

- Track active weighted stake on a per-user basis and exclude the withdrawer's full remaining weight from penalty redistribution.
- If no third-party active weight remains after excluding the withdrawer, route the penalty to `treasury`.
- Add a regression test covering the case where the same user has multiple positions and must not recover its own penalty through a sibling position.

---

### [Medium] Per-position rounding allows low-decimal tokens to reduce or bypass early-exit penalties

- Affected code: `src/ChronosVault.sol:284-285`

#### Description

The early-exit penalty is calculated per position as:

```solidity
penalty = principal * earlyExitPenaltyBps / BPS_DENOMINATOR;
```

Because the result is floored for each position independently, a user can split the same total principal across many small positions and reduce the aggregate penalty through repeated rounding. For 18-decimal assets this is usually negligible dust, but the contract does not enforce token decimals or a minimum effective penalty, so the issue becomes meaningful for low-decimal tokens.

#### Impact

- Early-exit costs can be reduced through stake splitting.
- The effect is especially relevant for low-decimal assets.
- The intended economic deterrent for early withdrawal is weakened.

#### Example

- With a 10% penalty, a single `90` unit position incurs a `9` unit penalty.
- If the same total is split into 10 positions of `9` units each, each position incurs a `0` unit penalty after flooring.
- The total penalty paid across all positions is therefore much lower than intended.

#### Recommendation

- Compute penalties on an aggregated amount rather than fully independently per position.
- Or enforce a minimum stake amount and/or a minimum non-zero penalty threshold.
- If the protocol is intended to support only standard 18-decimal ERC20 assets, promote that assumption from documentation into an explicit constraint or deployment check.

## Downgraded Leads And Observations

The following items were recorded during the audit but were not counted as formal findings:

### 1. Non-standard ERC20 compatibility risk

Both `stake()` and `fundRewards()` account using the nominal `amount` argument rather than the actual balance delta received by the vault. That can break accounting for fee-on-transfer, rebasing, callback-heavy, or later-upgraded tokens that under-deliver on transfer.

This was not elevated to a formal finding because the repository explicitly documents these token types as out of scope:

- `docs/AUDIT_PREP.md:55-63`
- `docs/KNOWN_ISSUES.md:18-21`

If the project wants to turn that documentation-only assumption into an on-chain guarantee, `stake()` and `fundRewards()` should either account by balance delta or reject non-standard tokens explicitly.

### 2. `stake()` remains available during emergency mode

`stake()` is gated by `whenNotPaused` but not by `emergencyMode`, while `claim()` and normal `withdraw()` are blocked once emergency mode is enabled. That creates state semantics that are somewhat inconsistent: users can still deposit in emergency mode and then only recover principal via `emergencyWithdraw()`.

This was treated as a UX/state-model concern rather than a confirmed loss-of-funds issue, so it was not promoted to a formal finding.

### 3. Reward distribution remainder dust

`_distributeRewards()` uses integer division when updating the accumulator, so repeated small reward additions can leave undistributed dust in the contract. The repository already describes this as a known design limitation, and no concrete profitable exploit path was established.

## Validation

The following commands were run locally before finalizing this report:

- `forge fmt --check`
- `forge build`
- `forge test`

Results:

- `forge fmt --check`: passed
- `forge build`: passed
- `forge test`: passed, 69/69 tests passed

## Conclusion

Chronos Vault's core reward accumulator, zero-staker routing, and pause/emergency primitives are generally straightforward and reasonably well covered by tests. However, the early-withdraw penalty logic contains a clear high-severity flaw: in a multi-position setup, the exiting user can reclaim its own penalty through another active position.

That issue should be fixed before relying on the penalty system as an economic control. After remediation, the test suite should be extended to cover:

- sibling-position penalty isolation for the same user
- low-decimal penalty rounding behavior
- non-standard ERC20 defenses if token compatibility is expanded beyond the current documented assumptions
