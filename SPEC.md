# Chronos Vault Specification

## 1. Overview

Chronos Vault is a single-asset staking protocol where users deposit one ERC20 token into the vault and choose a predefined lock duration. Users earn rewards from:
1. an admin-funded reward pool
2. penalties paid by users who withdraw before their lock expires

The protocol redistributes value from early exits to remaining stakers.

This project is designed to be self-contained and suitable for AI-assisted development and auditing.

---

## 2. Terminology

### Staking token
The single ERC20 token used for:
- deposit
- withdrawal
- reward funding
- reward claiming

For simplicity, the staking token and reward token are the same token.

### Position
A user stake record containing:
- deposited principal
- lock tier
- unlock timestamp
- weighted stake units
- reward accounting fields
- withdrawn status

### Weighted stake units
Reward distribution is based on weighted units, not raw deposited principal.

Example:
- 100 tokens at 30d with 1.0x weight => 100 weighted units
- 100 tokens at 90d with 1.5x weight => 150 weighted units
- 100 tokens at 180d with 2.0x weight => 200 weighted units

### Early exit penalty
A percentage haircut applied to principal when withdrawing before lock expiry.

### Reward pool
An internal accounting concept. It is not a separate balance bucket contract; it is represented by tokens held by the vault and made claimable through reward distribution accounting.

---

## 3. Product requirements

### 3.1 Users can stake
A user can create a new position by depositing staking tokens and selecting a supported lock tier.

Requirements:
- stake amount must be > 0
- lock tier must be one of supported predefined tiers
- contract must transfer staking tokens from user to vault
- a new position must be created
- position principal and weighted units must be recorded
- reward accounting must be initialized correctly

### 3.2 Users can hold multiple positions
A user may have multiple stake positions with different lock durations and timestamps.

Requirements:
- positions must be independently tracked
- claiming and withdrawing should work per position or via helper batch functions
- position IDs should be unique and deterministic or sequential

Recommended approach:
- global incremental `nextPositionId`
- mapping from `positionId => Position`
- mapping from `user => uint256[] positionIds`

### 3.3 Users earn rewards
Rewards accrue based on weighted stake units.

Requirements:
- rewards must depend on weighted stake, not raw amount
- rewards must be claimable without withdrawing principal
- claims must not affect principal
- claiming must update reward debt / accounting correctly

### 3.4 Admin can fund rewards
Owner/admin can add reward tokens into the system.

Requirements:
- funded rewards are distributed to active weighted stake
- if no one is staked, rewards must not become claimable by a future first staker
- reward accounting must remain economically safe in the zero-staker case

Required behavior:
- if `totalWeightedStaked == 0`, funded rewards MUST NOT be stored for later user distribution
- instead, such rewards MUST be transferred or accounted to a `treasury` destination
- if `totalWeightedStaked > 0`, rewards are distributed immediately through the reward accumulator

Rationale:
- this avoids a zero-staker MEV attack where the first staker captures historical undistributed rewards with negligible stake size

### 3.5 Users can withdraw after lock expiry
After unlock time, a user may fully withdraw principal without penalty.

Requirements:
- full principal is returned
- pending rewards can either:
  - be auto-claimed on withdraw, or
  - require separate claim

Preferred behavior:
- auto-claim pending rewards during withdrawal for better UX

### 3.6 Users can withdraw before lock expiry
If a user exits early, a penalty is deducted from principal.

Requirements:
- penalty rate must be protocol-defined
- user receives `principal - penalty + pending rewards`
- penalty amount must be redistributed safely
- the exiting user must not receive any share of the penalty they pay
- if there are no remaining stakers after removing the exiting position, penalty must not become claimable by a future first staker

Required behavior:
- remove the exiting position from active weighted stake before redistributing penalty
- if remaining `totalWeightedStaked > 0`, redistribute penalty through the reward accumulator
- if remaining `totalWeightedStaked == 0`, route the penalty to `treasury`

Rationale:
- this prevents both self-redistribution and zero-staker capture attacks

### 3.7 Admin can pause
Owner can pause core actions.

Pause behavior:
- staking disabled
- claiming disabled
- early withdrawal disabled
- matured withdrawal allowed
- emergency withdrawal enabled only if emergency mode is activated

Required behavior:
- when paused:
  - `stake` MUST revert
  - `claim` MUST revert
  - early `withdraw` MUST revert
  - matured `withdraw` MUST remain available
  - `emergencyWithdraw` is only available if emergency mode is enabled

Rationale:
- pause should stop new risk and reward-sensitive state transitions, but should not unnecessarily trap users whose positions have already matured

### 3.8 Emergency mode
Owner can enable emergency mode for user principal recovery.

Requirements:
- emergency mode is an exceptional state
- in emergency mode, users can withdraw principal
- reward claiming is disabled
- no early exit penalty applies in emergency mode
- unclaimed rewards from an emergency-withdrawn position must not become permanently locked in the contract

Required behavior:
- emergency withdraw returns principal only
- bypasses lock restriction
- does not pay pending rewards to the exiting user
- forfeited pending rewards MUST be handled explicitly:
  - if remaining `totalWeightedStaked > 0`, redistribute forfeited rewards through the reward accumulator
  - if remaining `totalWeightedStaked == 0`, route forfeited rewards to `treasury`
- once emergency mode is on, it is irreversible for MVP

Rationale:
- this preserves accounting integrity and avoids locked reward dust

---

## 4. Functional design

### 4.1 Lock tiers

Use fixed configuration stored on-chain.

Suggested values:

| Tier ID | Duration | Weight (scaled 1e18) |
|--------|----------|----------------------|
| 0 | 30 days  | 1e18 |
| 1 | 90 days  | 1.5e18 |
| 2 | 180 days | 2e18 |

Implementation note:
- use `weight` scaled by `1e18`
- weighted units = `amount * weight / 1e18`

### 4.2 Penalty model

Use a simple fixed penalty model for MVP:
- early exit penalty = `principal * earlyExitPenaltyBps / 10000`

Suggested default:
- `earlyExitPenaltyBps = 1000` (10%)

Admin may update it within capped bounds.

Recommended cap:
- `MAX_PENALTY_BPS = 3000` (30%)

### 4.3 Reward accounting model

Use the standard accumulated reward-per-weighted-share pattern.

State suggestions:
- `totalPrincipalStaked`
- `totalWeightedStaked`
- `accRewardPerWeightedShare` scaled by `1e18` or `1e24`
- `pendingUndistributedRewards`

For each position:
- `principal`
- `weightedAmount`
- `rewardDebt`
- `owner`
- `unlockTime`
- `tierId`
- `withdrawn`

Pending reward formula:
- `pending = weightedAmount * accRewardPerWeightedShare / ACC_PRECISION - rewardDebt`

On stake:
- distribute pending-undistributed rewards first if appropriate
- create position
- set rewardDebt using current accumulator

On claim:
- compute pending
- update rewardDebt
- transfer reward tokens

On withdraw:
- compute pending
- remove weighted stake from totals
- if early exit, compute penalty and redistribute it
- mark withdrawn
- transfer user payout
- update accounting safely

### 4.4 Penalty redistribution timing

Penalty should be redistributed after the exiting position is removed from total weighted stake, so the exiter does not receive a share of their own penalty redistribution.

Correct high-level sequence for early withdrawal:
1. compute pending reward for position
2. remove position weighted amount from total weighted stake
3. compute penalty
4. redistribute penalty to remaining weighted stake, or pendingUndistributedRewards if none remain
5. mark position withdrawn / zeroed
6. transfer payout

This ordering is important.

### 4.5 Reward funding

### 4.5 Reward funding

`fundRewards(amount)`:
- transfer reward token from admin to vault
- if `totalWeightedStaked == 0`
  - funded rewards MUST NOT be stored as future user-distributable rewards
  - they MUST instead be routed to `treasury`
- else
  - update `accRewardPerWeightedShare`

Important:
- the protocol MUST NOT allow a future first staker to capture rewards funded while no users were actively staked

### 4.6 Auto-claim on withdraw

Preferred behavior:
- withdrawing a position should include both principal payout and pending rewards
- this avoids stranded user rewards

---

## 5. Data model

## 5.1 Position struct

Suggested struct:

```solidity
struct Position {
    address owner;
    uint128 principal;
    uint128 weightedAmount;
    uint64 unlockTime;
    uint32 tierId;
    bool withdrawn;
    uint256 rewardDebt;
}
```
Exact packing may change if needed for clarity.

### 5.2 Core state

Suggested state variables:

- `IERC20 public immutable stakingToken;`
- `address public treasury;`
- `uint256 public nextPositionId;`
- `uint256 public totalPrincipalStaked;`
- `uint256 public totalWeightedStaked;`
- `uint256 public accRewardPerWeightedShare;`
- `uint256 public pendingUndistributedRewards;`
- `uint256 public earlyExitPenaltyBps;`
- `bool public emergencyMode;`

Mappings:
- `mapping(uint256 => Position) public positions;`
- `mapping(address => uint256[]) public userPositionIds;`

Lock config:
- `mapping(uint256 => LockTier) public lockTiers;`

Suggested lock tier struct:

```solidity
struct LockTier {
    uint64 duration;
    uint192 weight;
    bool enabled;
}
```
Notes:

- treasury is the sink for rewards, penalties, or forfeited rewards that arise when there are no active stakers to redistribute to safely
- pendingUndistributedRewards may still exist only if later retained for internal accounting convenience, but MUST NOT be used in a way that allows zero-staker reward capture by a future first staker
---

## 6. Access control

Use `Ownable` for MVP.

Owner actions:
- set / update lock tiers
- set early exit penalty within cap
- fund rewards
- set treasury address
- pause / unpause
- enable emergency mode

No other privileged roles needed for MVP.
---

## 7. UX/API requirements

Suggested external functions:

### User functions
- `stake(uint256 amount, uint256 tierId)`
- `claim(uint256 positionId)`
- `claimBatch(uint256[] calldata positionIds)`
- `withdraw(uint256 positionId)`
- `emergencyWithdraw(uint256 positionId)`

### View functions
- `pendingRewards(uint256 positionId) view returns (uint256)`
- `getUserPositionIds(address user) view returns (uint256[] memory)`
- `getPosition(uint256 positionId) view returns (Position memory)`
- `previewWithdraw(uint256 positionId) view returns (uint256 principalOut, uint256 rewardOut, uint256 penalty)`

### Admin functions
- `fundRewards(uint256 amount)`
- `setPenaltyBps(uint256 newPenaltyBps)`
- `setLockTier(uint256 tierId, uint64 duration, uint256 weight, bool enabled)`
- `pause()`
- `unpause()`
- `enableEmergencyMode()`

---

## 8. Events

Suggested events:

- `Staked(address indexed user, uint256 indexed positionId, uint256 amount, uint256 tierId, uint256 unlockTime, uint256 weightedAmount)`
- `Claimed(address indexed user, uint256 indexed positionId, uint256 reward)`
- `Withdrawn(address indexed user, uint256 indexed positionId, uint256 principalOut, uint256 rewardOut, uint256 penalty)`
- `RewardsFunded(address indexed funder, uint256 amount)`
- `PenaltyUpdated(uint256 oldPenaltyBps, uint256 newPenaltyBps)`
- `LockTierUpdated(uint256 indexed tierId, uint64 duration, uint256 weight, bool enabled)`
- `EmergencyModeEnabled()`

---

## 9. Edge cases and correctness rules

### 9.1 No reward leakage
Rewards must not be claimable twice.

### 9.2 No penalty self-redistribution
An early exiter must not benefit from the penalty they pay.

### 9.3 Zero-staker reward and penalty handling
If rewards, penalties, or forfeited rewards arise when no weighted stake exists, they must not become claimable by a future first staker.

Required behavior:
- if `totalWeightedStaked == 0`, such value MUST be routed to `treasury`
- the protocol MUST NOT accumulate user-distributable rewards across a zero-staker interval in a way that enables first-staker capture

### 9.4 Withdrawn positions are terminal
Once withdrawn:
- cannot claim
- cannot withdraw again
- pending reward should be zero
- position remains only as historical record

### 9.5 Ownership checks
Only position owner may claim or withdraw that position.

### 9.6 Pause checks
When paused:
- disabled functions must revert consistently
- staking must be disabled
- claiming must be disabled
- early withdrawal must be disabled
- matured withdrawal must remain available

### 9.7 Emergency withdraw semantics
Emergency withdraw should:
- ignore lock expiration
- return principal only
- not charge penalty
- mark position withdrawn
- reduce totals correctly
- not leave forfeited pending rewards permanently stranded in the contract

Required behavior:
- calculate the position's pending rewards
- the user does not receive those pending rewards
- those forfeited rewards MUST be:
  - redistributed through `accRewardPerWeightedShare` if active weighted stake remains, or
  - routed to `treasury` if no active weighted stake remains


### 9.8 Rounding
Some dust from integer division is acceptable, but accounting should remain conservative and consistent.

---

## 10. Security constraints

Must use:
- `SafeERC20`
- `ReentrancyGuard`
- `Pausable`

Must avoid:
- external calls before state updates where unsafe
- ambiguous emergency semantics
- hidden admin drains
- overcomplicated upgrade patterns

Recommended patterns:
- checks-effects-interactions
- explicit ownership checks
- small internal helper functions for accounting updates

---

## 11. Testing requirements

At minimum, tests should cover:

### Basic flows
- single user stake / claim / withdraw after expiry
- single user early withdraw with penalty
- multiple users with different tiers
- admin-funded rewards distribution

### Accounting flows
- penalty redistributed to remaining users
- exiter does not receive their own penalty redistribution
- rewards scale by weighted stake, not principal only
- rewards funded during a zero-staker state cannot be captured by a future first staker
- penalties arising with zero remaining stakers are routed to treasury
- forfeited rewards on emergency withdraw are not left as locked dust

### Failure cases
- stake zero amount
- invalid tier
- unauthorized claim / withdraw
- double withdraw
- claim withdrawn position
- pause behavior
- emergency mode behavior

### Time-based cases
- withdraw just before unlock
- withdraw at unlock
- withdraw after unlock
- matured withdraw still works while paused
- early withdraw reverts while paused

### Invariant-minded cases
- total distributed rewards should never exceed funded rewards + collected penalties - treasury-routed amounts
- total principal out should match principal in minus valid penalties
- contract balance accounting should remain explainable
- zero-staker intervals must not create claimable historical reward windfalls for new entrants


## 12. Suggested implementation order

1. project scaffold
2. token mock
3. lock tier config
4. position storage and stake flow
5. reward accumulator
6. claim flow
7. withdraw flow
8. early penalty redistribution
9. pause / emergency mode
10. tests
11. cleanup / docs

---

## 13. Explicit design decisions for MVP

To reduce ambiguity, use these choices unless there is a strong reason not to:

- one staking token only
- reward token is the same token
- multiple positions per user allowed
- fixed lock tiers
- fixed early exit penalty bps
- auto-claim on normal withdraw
- emergency withdraw returns principal only
- forfeited rewards from emergency withdraw are redistributed to remaining stakers, or routed to treasury if none remain
- rewards or penalties arising during zero-staker periods are routed to treasury
- matured withdrawals remain allowed while paused
- no partial withdrawals
- no position merging
- no position transfer / NFT representation
- no upgradeability
- no proxy pattern

---

## 14. Out of scope

Do not implement:
- ERC4626 wrapper behavior
- permit support
- referral logic
- vesting NFTs
- governance token emissions
- delegated claiming
- off-chain signatures
- snapshots
- external price feeds
- multicall optimization unless trivial