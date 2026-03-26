# Chronos Vault Task Breakdown

This file defines the implementation plan for Codex or any coding agent.

The project should be built incrementally in small, reviewable steps. Do not attempt to build everything in one giant change.

## Milestone 0 - Project scaffold

### Goal
Set up a minimal Foundry project structure for Chronos Vault.

### Tasks
- initialize Foundry project layout if not present
- add OpenZeppelin dependency if needed
- create base directories:
  - `src/`
  - `src/interfaces/`
  - `src/libraries/`
  - `test/`
  - `script/`
- add `foundry.toml` if needed
- add formatting and test commands to README if missing

### Deliverable
A clean project skeleton that compiles.

---

## Milestone 1 - Mock token

### Goal
Create a simple ERC20 token for local testing.

### Tasks
- implement `MockERC20.sol`
- mint initial supply in constructor or expose mint for tests only
- keep implementation simple and test-friendly

### Deliverable
Tests can use a staking token without external dependencies.

---

## Milestone 2 - Core storage and config

### Goal
Create the main contract and define storage, structs, and admin configuration.

### Tasks
- create `ChronosVault.sol`
- add constructor with staking token address
- define:
  - `Position`
  - `LockTier`
- add state variables:
  - position id counter
  - total principal
  - total weighted stake
  - accumulator
  - pending undistributed rewards
  - penalty bps
  - emergency mode
- add lock tier configuration
- initialize default tiers:
  - 30d / 1.0x
  - 90d / 1.5x
  - 180d / 2.0x
- add admin setters:
  - `setPenaltyBps`
  - `setLockTier`

### Deliverable
Contract compiles with configuration and storage in place.

---

## Milestone 3 - Stake flow

### Goal
Allow users to create staking positions.

### Tasks
- implement `stake(amount, tierId)`
- validate:
  - not paused
  - amount > 0
  - tier exists and enabled
- compute:
  - unlock timestamp
  - weighted amount
- transfer tokens in
- create position
- append position ID to user list
- update global totals
- initialize reward debt correctly
- emit event

### Deliverable
Users can create positions and position data is correct.

### Tests
- stake succeeds with valid amount and tier
- zero amount reverts
- invalid tier reverts
- multiple positions per user work

---

## Milestone 4 - Reward funding and accumulator

### Goal
Implement the reward distribution backbone.

### Tasks
- implement internal accumulator update helpers
- implement `fundRewards(amount)`
- if no weighted stake exists:
  - add to `pendingUndistributedRewards`
- otherwise:
  - distribute immediately through accumulator
- implement helper to roll pending undistributed rewards into active distribution when applicable

### Deliverable
The vault can accept reward funding and update reward accounting.

### Tests
- funding with no stakers goes to pending undistributed
- funding with stakers updates accumulator
- pending undistributed gets distributed later

---

## Milestone 5 - Reward views and claim flow

### Goal
Users can view and claim rewards.

### Tasks
- implement `pendingRewards(positionId)`
- implement `claim(positionId)`
- optional: implement `claimBatch(positionIds)`
- ensure only owner can claim
- ensure withdrawn positions cannot claim
- transfer reward tokens safely
- update reward debt after claim
- emit event

### Deliverable
Users can claim accrued rewards safely.

### Tests
- user can claim funded rewards
- claim updates debt correctly
- double claim without new rewards returns zero or no-op as designed
- unauthorized claim reverts

---

## Milestone 6 - Withdraw after expiry

### Goal
Users can withdraw after lock expiry with no penalty.

### Tasks
- implement withdraw path for matured positions
- compute pending rewards
- remove principal and weighted amount from totals
- mark position withdrawn
- transfer principal + rewards
- emit event

### Deliverable
Users can exit matured positions safely.

### Tests
- withdraw after unlock returns full principal
- pending rewards auto-claimed
- second withdraw reverts

---

## Milestone 7 - Early withdraw with penalty redistribution

### Goal
Users can withdraw before expiry with a penalty, and remaining stakers benefit.

### Tasks
- detect early withdrawal
- compute penalty using penalty bps
- compute user payout
- remove position weighted amount before redistributing penalty
- redistribute penalty via accumulator if remaining weighted stake exists
- otherwise move penalty to pending undistributed rewards
- mark withdrawn and transfer payout

### Deliverable
Early exits work and penalties are redistributed correctly.

### Tests
- early withdraw deducts penalty
- remaining stakers receive redistributed value
- exiter does not get their own penalty back
- last staker penalty goes to pending undistributed rewards

---

## Milestone 8 - Pause and emergency mode

### Goal
Add operational safety controls.

### Tasks
- integrate `Pausable`
- add `pause()` / `unpause()`
- add `enableEmergencyMode()`
- implement `emergencyWithdraw(positionId)`
- emergency withdraw:
  - principal only
  - bypass lock
  - no penalty
  - no reward
  - update totals and mark withdrawn

### Deliverable
Operational controls and emergency escape are functional.

### Tests
- paused stake reverts
- paused normal claim/withdraw behavior matches spec
- emergency withdraw works
- emergency withdraw forfeits rewards
- emergency withdraw ignores lock

---

## Milestone 9 - View helpers and UX polish

### Goal
Add useful helper functions for frontends and testing.

### Tasks
- implement `getUserPositionIds(user)`
- implement `getPosition(positionId)`
- implement `previewWithdraw(positionId)`

### Deliverable
Read APIs are adequate for integration and validation.

---

## Milestone 10 - Test hardening

### Goal
Improve confidence in accounting and edge cases.

### Tasks
- add tests for:
  - multiple users with different weights
  - multiple reward funding rounds
  - claim then withdraw
  - withdraw exactly at unlock
  - withdraw just before unlock
  - pause edge cases
  - emergency after rewards exist
- add invariant-minded assertions where practical

### Deliverable
Robust test suite with meaningful edge coverage.

---

## Milestone 11 - Documentation and cleanup

### Goal
Finalize project quality.

### Tasks
- improve comments on accounting logic
- document key invariants
- clean naming and event consistency
- update README with build/test instructions
- ensure formatting and test suite pass

### Deliverable
A clean, reviewable MVP implementation.

---

# Suggested PR strategy

Each milestone should ideally be its own PR or at least its own reviewable commit group.

Preferred order:
1. scaffold
2. mock token
3. storage/config
4. stake
5. rewards backbone
6. claim
7. normal withdraw
8. early withdraw penalty redistribution
9. pause/emergency
10. helpers/tests/docs

Do not skip directly to a final all-in-one implementation unless explicitly requested.
