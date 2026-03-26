// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ChronosVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACC_PRECISION = 1e18;
    uint256 public constant WEIGHT_SCALE = 1e18;

    uint256 public constant TIER_30_DAYS = 0;
    uint256 public constant TIER_90_DAYS = 1;
    uint256 public constant TIER_180_DAYS = 2;

    error ZeroAddress();
    error InvalidLockTierConfig();

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

    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public userPositionIds;
    mapping(uint256 => LockTier) public lockTiers;

    event LockTierUpdated(uint256 indexed tierId, uint64 duration, uint256 weight, bool enabled);

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

    function _setLockTier(uint256 tierId, uint64 duration, uint256 weight, bool enabled) internal {
        if (duration == 0 || weight == 0) {
            revert InvalidLockTierConfig();
        }

        lockTiers[tierId] = LockTier({duration: duration, weight: weight, enabled: enabled});

        emit LockTierUpdated(tierId, duration, weight, enabled);
    }
}
