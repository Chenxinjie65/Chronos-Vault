// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IChronosVault
/// @notice External interface for the Chronos Vault single-asset staking MVP.
/// @dev Rewards are distributed by weighted stake units instead of raw principal.
interface IChronosVault {
    /// @notice User position state tracked by the vault.
    /// @param owner Position owner that is allowed to claim or withdraw the position.
    /// @param principal Staked principal denominated in the staking token.
    /// @param weightedAmount Reward weight used for accumulator accounting.
    /// @param rewardDebt Accumulator snapshot used to prevent double claiming.
    /// @param unlockTime Earliest timestamp at which the position may withdraw without penalty.
    /// @param tierId Lock tier selected when the position was created.
    /// @param withdrawn Terminal flag that disables further reward accrual and exits.
    struct Position {
        address owner;
        uint256 principal;
        uint256 weightedAmount;
        uint256 rewardDebt;
        uint64 unlockTime;
        uint256 tierId;
        bool withdrawn;
    }

    /// @notice Lock configuration used to derive reward weight and unlock time.
    /// @param duration Lock duration in seconds.
    /// @param weight Reward multiplier scaled by `WEIGHT_SCALE` in the implementation.
    /// @param enabled Whether the tier can be selected for new stakes.
    struct LockTier {
        uint64 duration;
        uint256 weight;
        bool enabled;
    }

    /// @notice Emitted when the owner updates or seeds a lock tier.
    event LockTierUpdated(uint256 indexed tierId, uint64 duration, uint256 weight, bool enabled);

    /// @notice Emitted when a user opens a new staking position.
    event Staked(
        address indexed user,
        uint256 indexed positionId,
        uint256 amount,
        uint256 tierId,
        uint256 unlockTime,
        uint256 weightedAmount
    );

    /// @notice Emitted when the owner funds rewards for active stakers or treasury routing.
    event RewardsFunded(address indexed funder, uint256 amount);

    /// @notice Emitted when a position owner claims accrued rewards.
    event Claimed(address indexed user, uint256 indexed positionId, uint256 reward);

    /// @notice Emitted once when the owner enables principal-recovery mode.
    event EmergencyModeEnabled(address indexed account);

    /// @notice Emitted when emergency withdraw returns principal and forfeits pending rewards.
    event EmergencyWithdrawn(
        address indexed user, uint256 indexed positionId, uint256 principalOut, uint256 forfeitedReward
    );

    /// @notice Emitted when a normal withdraw exits a position.
    event Withdrawn(
        address indexed user, uint256 indexed positionId, uint256 principalOut, uint256 rewardOut, uint256 penalty
    );

    /// @notice Emitted when the owner updates the early exit penalty.
    event EarlyExitPenaltyUpdated(uint256 oldPenaltyBps, uint256 newPenaltyBps);

    /// @notice Emitted when the owner updates the treasury address.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice ERC20 token used for both staking principal and rewards.
    function stakingToken() external view returns (IERC20);

    /// @notice Treasury that receives rewards, penalties, or forfeited rewards during zero-staker intervals.
    function treasury() external view returns (address);

    /// @notice Next position id to be assigned on stake.
    function nextPositionId() external view returns (uint256);

    /// @notice Sum of all active principal across positions.
    function totalPrincipalStaked() external view returns (uint256);

    /// @notice Sum of all active weighted stake used for reward distribution.
    function totalWeightedStaked() external view returns (uint256);

    /// @notice Global reward accumulator per weighted share.
    function accRewardPerWeightedShare() external view returns (uint256);

    /// @notice Early exit penalty in basis points applied before unlock.
    function earlyExitPenaltyBps() external view returns (uint256);

    /// @notice Maximum early exit penalty allowed by admin configuration.
    function MAX_EARLY_EXIT_PENALTY_BPS() external pure returns (uint256);

    /// @notice Whether emergency mode has been permanently enabled for this MVP.
    function emergencyMode() external view returns (bool);

    /// @notice Returns a configured lock tier by id.
    function lockTiers(uint256 tierId) external view returns (uint64 duration, uint256 weight, bool enabled);

    /// @notice Stakes `amount` into a new position under the chosen lock tier.
    /// @dev Reverts while paused or if the tier is invalid. Rewards start from the current accumulator snapshot.
    /// @param amount Principal amount to stake.
    /// @param tierId Lock tier id to apply.
    /// @return positionId Newly created position id.
    function stake(uint256 amount, uint256 tierId) external returns (uint256 positionId);

    /// @notice Funds additional rewards.
    /// @dev If no active weighted stake exists, the amount is routed directly to treasury to avoid future windfalls.
    /// @param amount Reward amount to fund.
    function fundRewards(uint256 amount) external;

    /// @notice Returns pending rewards for an active position.
    /// @dev Withdrawn or missing positions return zero.
    /// @param positionId Position id to inspect.
    /// @return reward Pending reward amount claimable by the position owner.
    function pendingRewards(uint256 positionId) external view returns (uint256 reward);

    /// @notice Returns all position ids owned by `user` in insertion order.
    function getUserPositionIds(address user) external view returns (uint256[] memory);

    /// @notice Returns the stored position record for `positionId`.
    /// @dev Withdrawn positions remain queryable for historical inspection.
    function getPosition(uint256 positionId) external view returns (Position memory);

    /// @notice Previews the currently available exit path for a position.
    /// @dev
    /// - Missing or withdrawn positions return all zeros.
    /// - Emergency mode previews the emergency path: principal only, zero reward, zero penalty.
    /// - Normal mode previews either a mature withdrawal or an early exit with penalty.
    /// @param positionId Position id to inspect.
    /// @return principalOut Principal amount currently expected to be returned.
    /// @return rewardOut Reward amount currently expected to be paid in normal mode.
    /// @return penalty Penalty currently expected to be charged before unlock.
    function previewWithdraw(uint256 positionId)
        external
        view
        returns (uint256 principalOut, uint256 rewardOut, uint256 penalty);

    /// @notice Claims pending rewards for an active position.
    /// @dev Disabled while paused or in emergency mode.
    /// @param positionId Position id to claim.
    /// @return reward Claimed reward amount.
    function claim(uint256 positionId) external returns (uint256 reward);

    /// @notice Claims pending rewards across multiple positions owned by the caller.
    /// @dev Reverts if any supplied position is unauthorized or withdrawn. Disabled while paused or in emergency mode.
    /// @param positionIds Position ids to claim in order.
    /// @return totalReward Total reward claimed across all positions.
    function claimBatch(uint256[] calldata positionIds) external returns (uint256 totalReward);

    /// @notice Withdraws an active position through the normal path.
    /// @dev
    /// - Matured withdrawals return principal plus pending rewards.
    /// - Early withdrawals charge a penalty and redistribute or route that value away from the exiter.
    /// - Disabled entirely in emergency mode.
    /// @param positionId Position id to withdraw.
    function withdraw(uint256 positionId) external;

    /// @notice Withdraws principal only once emergency mode is enabled.
    /// @dev Pending rewards are forfeited and redistributed to active stakers or routed to treasury if none remain.
    /// @param positionId Position id to withdraw.
    function emergencyWithdraw(uint256 positionId) external;

    /// @notice Updates the early exit penalty in basis points.
    function setEarlyExitPenaltyBps(uint256 newPenaltyBps) external;

    /// @notice Updates the treasury used for zero-staker routing.
    function setTreasury(address newTreasury) external;

    /// @notice Creates or updates a lock tier.
    function setLockTier(uint256 tierId, uint64 duration, uint256 weight, bool enabled) external;

    /// @notice Pauses stake, claim, and early withdraw.
    /// @dev Matured withdraw remains available while paused.
    function pause() external;

    /// @notice Unpauses normal operation.
    function unpause() external;

    /// @notice Enables irreversible emergency mode for principal recovery.
    function enableEmergencyMode() external;
}
