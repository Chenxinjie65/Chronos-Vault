# AGENTS.md

This file defines how coding agents should work in this repository.

The goal is not just to "make it compile", but to produce a clean, testable, reviewable Chronos Vault MVP.

## 1. Project mission

Build a single-asset staking protocol named Chronos Vault.

Users:
- stake one ERC20 token
- choose a lock duration from fixed tiers
- earn rewards based on weighted stake units
- pay a penalty if exiting early

Penalties and admin-funded rewards should benefit remaining stakers through the same internal accounting framework.

## 2. Primary success criteria

A successful implementation must:

- compile cleanly
- have clear reward accounting
- support multiple positions per user
- correctly redistribute early-exit penalties
- include strong tests
- avoid unnecessary complexity

## 3. Non-goals

Do not add:
- upgradeability
- proxy patterns
- governance
- external protocol integrations
- ERC4626 wrappers
- NFT positions
- partial withdrawals
- referral systems
- multicall-heavy abstractions
- gas golfing that harms clarity

## 4. Implementation style

Prefer:
- simple and explicit code
- small internal helper functions
- conservative accounting
- readability over over-abstraction
- comments around tricky math

Avoid:
- deep inheritance trees
- unnecessary libraries
- speculative extensibility
- hidden control flow

## 5. Technical assumptions

Unless explicitly changed, assume:
- Solidity `^0.8.24`
- Foundry
- OpenZeppelin contracts available
- staking token == reward token
- same-token rewards are acceptable for this MVP
- fixed lock tiers
- fixed penalty bps with owner-controlled capped update
- multiple positions per user
- auto-claim on normal withdraw
- emergency withdraw returns principal only
- forfeited rewards from emergency withdraw are redistributed to remaining stakers, or routed to treasury if none remain
- rewards, penalties, or forfeited rewards arising during zero-staker periods are routed to treasury
- matured withdrawals remain allowed while paused

## 6. Security requirements

Always consider:
- reentrancy
- checks-effects-interactions ordering
- reward debt correctness
- double-withdraw prevention
- ownership checks on positions
- zero-staker reward funding edge case
- zero-staker penalty redistribution edge case
- zero-staker forfeited reward edge case
- paused and emergency states

Use:
- `SafeERC20`
- `ReentrancyGuard`
- `Pausable`
- `Ownable`

Do not:
- transfer tokens before updating critical state where that could be unsafe
- allow withdrawn positions to claim again
- let an early exiter share in their own redistributed penalty
- accumulate user-distributable rewards across a zero-staker interval
- leave forfeited emergency-withdraw rewards stranded in the contract

## 7. Accounting rules

These are critical.

### 7.1 Rewards are distributed by weighted stake
Use weighted stake units for rewards, not raw principal.

### 7.2 Principal and reward power are different concepts
Keep principal accounting separate from weighted reward accounting.

### 7.3 Penalty redistribution ordering matters
For early withdraw:
1. compute pending reward
2. remove the exiting position from total weighted stake
3. compute and redistribute penalty to remaining stake, or route to treasury if no active stake remains
4. mark withdrawn
5. transfer payout

The exiter must not benefit from the penalty they pay.

### 7.4 No active stakers case
If rewards, penalties, or forfeited rewards arise while `totalWeightedStaked == 0`, they MUST be routed to `treasury` and MUST NOT be stored for later user distribution.

This rule exists to prevent zero-staker capture / first-staker windfall attacks.

### 7.5 Withdrawn positions are terminal
Once withdrawn:
- no claim
- no withdraw
- no reward accrual

### 7.6 Emergency withdraw reward handling
For emergency withdraw:
- return principal only
- do not pay pending rewards to the exiting user
- calculate forfeited pending rewards explicitly
- if active weighted stake remains, redistribute forfeited rewards through the reward accumulator
- if no active weighted stake remains, route forfeited rewards to treasury

Do not leave forfeited rewards stranded in contract balance.

### 7.7 Pause semantics
When paused:
- `stake` must be disabled
- `claim` must be disabled
- early `withdraw` must be disabled
- matured `withdraw` must remain available
- `emergencyWithdraw` is only available if emergency mode is enabled

## 8. Testing standards

Every milestone should include or update tests.

At minimum, tests should verify:
- happy path behavior
- permission checks
- edge timing behavior
- accounting correctness
- meaningful revert cases

Important cases:
- multiple users with different weights
- early withdraw penalty redistribution
- final remaining staker case
- zero-staker rewards funded cannot be captured by a future first staker
- penalties arising with zero remaining stakers are routed to treasury
- emergency withdraw forfeited rewards are not left as locked dust
- matured withdraw while paused
- paused behavior

## 9. Coding process rules

Before changing code:
1. summarize the task
2. identify assumptions
3. list files to modify
4. explain the implementation plan briefly

After changing code:
1. summarize what changed
2. list any tradeoffs
3. run relevant tests if possible
4. report remaining risks or TODOs

## 10. PR / commit expectations

Keep changes small and reviewable.

Preferred practice:
- one milestone per PR
- do not mix unrelated refactors into feature work
- add or update tests with each feature
- keep event names and revert behavior consistent

## 11. Comments and documentation

Add comments only where they provide real value.

Must comment:
- reward accumulator logic
- penalty redistribution ordering
- zero-staker treasury routing rules
- emergency mode semantics if non-obvious

Do not over-comment trivial getters or obvious assignment code.

## 12. When requirements are ambiguous

Do not invent major product behavior silently.

Use this decision rule:
- if ambiguity affects security or accounting, choose the most conservative implementation and explain it
- if ambiguity affects UX but not safety, follow SPEC.md preferred behavior
- if a requested change conflicts with SPEC.md, call out the conflict
- if AGENTS.md and SPEC.md ever conflict on accounting or safety behavior, follow SPEC.md and explicitly mention the conflict

## 13. Recommended file targets

Expected main files:
- `contracts/ChronosVault.sol`
- `contracts/MockERC20.sol`
- `test/ChronosVault.t.sol`

Optional additional files only if they improve clarity:
- helper libraries
- deployment scripts
- split test files

Avoid splitting into too many files for a small project.

## 14. Definition of done

The MVP is done when:
- staking works
- claim works
- mature withdraw works
- early withdraw penalty works
- penalties are redistributed correctly
- zero-staker value routing works correctly
- admin-funded rewards work
- pause and emergency mode work
- tests cover core and edge flows
- code is understandable without hidden assumptions
