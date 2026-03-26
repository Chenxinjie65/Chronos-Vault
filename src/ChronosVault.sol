// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ChronosVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACC_PRECISION = 1e24;
    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_EARLY_EXIT_PENALTY_BPS = 1_000;

    uint256 public constant TIER_30_DAYS = 0;
    uint256 public constant TIER_90_DAYS = 1;
    uint256 public constant TIER_180_DAYS = 2;

    error ZeroAddress();
    error InvalidAmount();
    error InvalidLockTierConfig();
    error InvalidTier(uint256 tierId);
    error InvalidWeightedAmount();
    error NotPositionOwner();
    error PositionWithdrawn();
    error PositionNotMatured();
    error EmergencyModeNotEnabled();
    error EmergencyModeAlreadyEnabled();
    error EmergencyModeActive();

    struct Position {
        address owner;
        uint256 principal;
        uint256 weightedAmount;
        uint256 rewardDebt;
        uint64 unlockTime;
        uint256 tierId;
        bool withdrawn;
    }

    struct LockTier {
        uint64 duration;
        uint256 weight;
        bool enabled;
    }

    IERC20 public immutable stakingToken;
    // Future zero-staker rewards, penalties, and forfeited rewards are routed here.
    address public treasury;

    uint256 public nextPositionId;
    uint256 public totalPrincipalStaked;
    uint256 public totalWeightedStaked;
    uint256 public accRewardPerWeightedShare;
    uint256 public earlyExitPenaltyBps = DEFAULT_EARLY_EXIT_PENALTY_BPS;
    bool public emergencyMode;

    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public userPositionIds;
    mapping(uint256 => LockTier) public lockTiers;

    event LockTierUpdated(uint256 indexed tierId, uint64 duration, uint256 weight, bool enabled);
    event Staked(
        address indexed user,
        uint256 indexed positionId,
        uint256 amount,
        uint256 tierId,
        uint256 unlockTime,
        uint256 weightedAmount
    );
    event RewardsFunded(address indexed funder, uint256 amount);
    event Claimed(address indexed user, uint256 indexed positionId, uint256 reward);
    event EmergencyModeEnabled(address indexed account);
    event EmergencyWithdrawn(
        address indexed user, uint256 indexed positionId, uint256 principalOut, uint256 forfeitedReward
    );
    event Withdrawn(
        address indexed user, uint256 indexed positionId, uint256 principalOut, uint256 rewardOut, uint256 penalty
    );

    constructor(address stakingToken_, address treasury_) Ownable(msg.sender) {
        if (stakingToken_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }

        stakingToken = IERC20(stakingToken_);
        treasury = treasury_;

        _setLockTier(TIER_30_DAYS, 30 days, 1e18, true);
        _setLockTier(TIER_90_DAYS, 90 days, 1.5e18, true);
        _setLockTier(TIER_180_DAYS, 180 days, 2e18, true);
    }

    function setLockTier(uint256 tierId, uint64 duration, uint256 weight, bool enabled) external onlyOwner {
        _setLockTier(tierId, duration, weight, enabled);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function enableEmergencyMode() external onlyOwner {
        if (emergencyMode) {
            revert EmergencyModeAlreadyEnabled();
        }

        emergencyMode = true;

        emit EmergencyModeEnabled(msg.sender);
    }

    function stake(uint256 amount, uint256 tierId) external whenNotPaused nonReentrant returns (uint256 positionId) {
        if (amount == 0) {
            revert InvalidAmount();
        }

        LockTier memory tier = lockTiers[tierId];
        if (!tier.enabled) {
            revert InvalidTier(tierId);
        }

        uint256 weightedAmount = _calculateWeightedAmount(amount, tier.weight);
        if (weightedAmount == 0) {
            revert InvalidWeightedAmount();
        }

        uint256 rewardDebt = _calculateRewardDebt(weightedAmount);
        uint256 unlockTime = block.timestamp + tier.duration;

        positionId = nextPositionId;
        nextPositionId = positionId + 1;

        positions[positionId] = Position({
            owner: msg.sender,
            principal: amount,
            weightedAmount: weightedAmount,
            rewardDebt: rewardDebt,
            unlockTime: uint64(unlockTime),
            tierId: tierId,
            withdrawn: false
        });

        userPositionIds[msg.sender].push(positionId);
        totalPrincipalStaked += amount;
        totalWeightedStaked += weightedAmount;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, positionId, amount, tierId, unlockTime, weightedAmount);
    }

    function fundRewards(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) {
            revert InvalidAmount();
        }

        if (totalWeightedStaked == 0) {
            if (treasury == address(0)) {
                revert ZeroAddress();
            }
            stakingToken.safeTransferFrom(msg.sender, treasury, amount);
            emit RewardsFunded(msg.sender, amount);
            return;
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        _distributeRewards(amount);

        emit RewardsFunded(msg.sender, amount);
    }

    function pendingRewards(uint256 positionId) public view returns (uint256) {
        Position memory position = positions[positionId];
        if (position.owner == address(0) || position.withdrawn) {
            return 0;
        }

        return _pendingRewards(position);
    }

    function getUserPositionIds(address user) external view returns (uint256[] memory) {
        return userPositionIds[user];
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function previewWithdraw(uint256 positionId)
        external
        view
        returns (uint256 principalOut, uint256 rewardOut, uint256 penalty)
    {
        Position memory position = positions[positionId];
        if (position.owner == address(0) || position.withdrawn) {
            return (0, 0, 0);
        }

        if (emergencyMode) {
            return (position.principal, 0, 0);
        }

        rewardOut = _pendingRewards(position);
        principalOut = position.principal;

        if (block.timestamp < position.unlockTime) {
            penalty = position.principal * earlyExitPenaltyBps / BPS_DENOMINATOR;
            principalOut -= penalty;
        }
    }

    function claim(uint256 positionId) external nonReentrant returns (uint256 reward) {
        _requireClaimAllowed();

        Position storage position = positions[positionId];
        if (position.owner != msg.sender) {
            revert NotPositionOwner();
        }
        if (position.withdrawn) {
            revert PositionWithdrawn();
        }

        reward = _pendingRewards(position);
        position.rewardDebt = _calculateRewardDebt(position.weightedAmount);

        if (reward > 0) {
            stakingToken.safeTransfer(msg.sender, reward);
        }

        emit Claimed(msg.sender, positionId, reward);
    }

    function withdraw(uint256 positionId) external nonReentrant {
        Position storage position = positions[positionId];
        if (position.owner != msg.sender) {
            revert NotPositionOwner();
        }
        if (position.withdrawn) {
            revert PositionWithdrawn();
        }
        if (emergencyMode) {
            revert EmergencyModeActive();
        }

        bool matured = block.timestamp >= position.unlockTime;
        if (!matured) {
            _requireEarlyWithdrawAllowed();
        }

        uint256 principal = position.principal;
        uint256 weightedAmount = position.weightedAmount;
        uint256 reward = _pendingRewards(position);
        uint256 accruedRewardDebt = _calculateRewardDebt(weightedAmount);

        totalPrincipalStaked -= principal;
        totalWeightedStaked -= weightedAmount;

        uint256 penalty;
        uint256 payoutPrincipal = principal;

        if (!matured) {
            penalty = principal * earlyExitPenaltyBps / BPS_DENOMINATOR;
            payoutPrincipal = principal - penalty;

            if (penalty > 0) {
                _routeOrDistributeValue(penalty);
            }
        }

        // Preserve the original position fields for historical inspection while
        // the withdrawn flag makes the position terminal for future actions.
        position.withdrawn = true;
        position.rewardDebt = accruedRewardDebt;

        stakingToken.safeTransfer(msg.sender, payoutPrincipal + reward);

        emit Withdrawn(msg.sender, positionId, payoutPrincipal, reward, penalty);
    }

    function emergencyWithdraw(uint256 positionId) external nonReentrant {
        if (!emergencyMode) {
            revert EmergencyModeNotEnabled();
        }

        Position storage position = positions[positionId];
        if (position.owner != msg.sender) {
            revert NotPositionOwner();
        }
        if (position.withdrawn) {
            revert PositionWithdrawn();
        }

        uint256 principal = position.principal;
        uint256 weightedAmount = position.weightedAmount;
        uint256 forfeitedReward = _pendingRewards(position);
        uint256 accruedRewardDebt = _calculateRewardDebt(weightedAmount);

        totalPrincipalStaked -= principal;
        totalWeightedStaked -= weightedAmount;

        position.withdrawn = true;
        position.rewardDebt = accruedRewardDebt;

        if (forfeitedReward > 0) {
            _routeOrDistributeValue(forfeitedReward);
        }

        stakingToken.safeTransfer(msg.sender, principal);

        emit EmergencyWithdrawn(msg.sender, positionId, principal, forfeitedReward);
    }

    function setEarlyExitPenaltyBps(uint256 newPenaltyBps) external onlyOwner {
        if (newPenaltyBps > BPS_DENOMINATOR) {
            revert InvalidAmount();
        }

        earlyExitPenaltyBps = newPenaltyBps;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) {
            revert ZeroAddress();
        }

        treasury = newTreasury;
    }

    function _setLockTier(uint256 tierId, uint64 duration, uint256 weight, bool enabled) internal {
        if (duration == 0 || weight == 0) {
            revert InvalidLockTierConfig();
        }

        lockTiers[tierId] = LockTier({duration: duration, weight: weight, enabled: enabled});

        emit LockTierUpdated(tierId, duration, weight, enabled);
    }

    function _requireClaimAllowed() internal view {
        if (emergencyMode) {
            revert EmergencyModeActive();
        }
        if (paused()) {
            revert Pausable.EnforcedPause();
        }
    }

    function _requireEarlyWithdrawAllowed() internal view {
        if (paused()) {
            revert Pausable.EnforcedPause();
        }
    }

    function _pendingRewards(Position memory position) internal view returns (uint256) {
        uint256 accumulatedReward = position.weightedAmount * accRewardPerWeightedShare / ACC_PRECISION;
        return accumulatedReward - position.rewardDebt;
    }

    function _calculateRewardDebt(uint256 weightedAmount) internal view returns (uint256) {
        return weightedAmount * accRewardPerWeightedShare / ACC_PRECISION;
    }

    function _calculateWeightedAmount(uint256 amount, uint256 weight) internal pure returns (uint256) {
        return amount * weight / WEIGHT_SCALE;
    }

    // All user-distributable value flows through the same accumulator. If no active
    // weighted stake remains, the value must be routed to treasury instead of stored.
    function _routeOrDistributeValue(uint256 amount) internal {
        if (totalWeightedStaked == 0) {
            if (treasury == address(0)) {
                revert ZeroAddress();
            }

            stakingToken.safeTransfer(treasury, amount);
            return;
        }

        _distributeRewards(amount);
    }

    // The accumulator is updated only against active weighted stake. Early-withdraw
    // paths remove the exiting position before calling this so the exiter cannot
    // share in its own penalty or forfeited rewards.
    function _distributeRewards(uint256 amount) internal {
        accRewardPerWeightedShare += amount * ACC_PRECISION / totalWeightedStaked;
    }
}
