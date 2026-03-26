// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChronosVault} from "../contracts/ChronosVault.sol";
import {MockERC20} from "../contracts/MockERC20.sol";

interface Vm {
    function warp(uint256 newTimestamp) external;
}

contract ChronosVaultTest {
    address internal constant TREASURY = address(0xBEEF);
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function testPendingRewardsMatchesWeightedDistribution() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 firstAmount = 100 ether;
        uint256 secondAmount = 100 ether;
        uint256 rewardAmount = 100 ether;

        _assertTrue(token.approve(address(vault), firstAmount + secondAmount + rewardAmount), "approve should succeed");

        uint256 firstPositionId = vault.stake(firstAmount, vault.TIER_90_DAYS());
        uint256 secondPositionId = vault.stake(secondAmount, vault.TIER_30_DAYS());
        vault.fundRewards(rewardAmount);

        _assertEq(vault.pendingRewards(firstPositionId), 60 ether, "unexpected first pending reward");
        _assertEq(vault.pendingRewards(secondPositionId), 40 ether, "unexpected second pending reward");
    }

    function testFundRewardsWithActiveStakersUpdatesAccumulator() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 90 ether;
        uint256 expectedAccumulator = rewardAmount * vault.ACC_PRECISION() / 150 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        vault.stake(stakeAmount, vault.TIER_90_DAYS());
        vault.fundRewards(rewardAmount);

        _assertEq(vault.accRewardPerWeightedShare(), expectedAccumulator, "unexpected accumulator");
        _assertEq(token.balanceOf(address(vault)), stakeAmount + rewardAmount, "unexpected vault token balance");
        _assertEq(token.balanceOf(TREASURY), 0, "treasury should not receive active rewards");
    }

    function testFundRewardsWithZeroStakersRoutesToTreasury() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 rewardAmount = 75 ether;

        _assertTrue(token.approve(address(vault), rewardAmount + 10 ether), "approve should succeed");

        vault.fundRewards(rewardAmount);

        _assertEq(vault.accRewardPerWeightedShare(), 0, "accumulator should remain unchanged");
        _assertEq(token.balanceOf(address(vault)), 0, "vault should not retain zero-staker rewards");
        _assertEq(token.balanceOf(TREASURY), rewardAmount, "treasury should receive zero-staker rewards");

        vault.stake(10 ether, vault.TIER_30_DAYS());

        (,,, uint256 rewardDebt,,,) = vault.positions(0);
        _assertEq(rewardDebt, 0, "future staker should not inherit routed rewards");
    }

    function testFundRewardsRevertsWhenTreasuryIsZero() public {
        (MockERC20 token, ChronosVaultTreasuryHarness vault) = _deployVaultHarness();
        uint256 rewardAmount = 75 ether;

        vault.setTreasuryForTest(address(0));
        _assertTrue(token.approve(address(vault), rewardAmount), "approve should succeed");

        (bool ok, bytes memory returndata) =
            address(vault).call(abi.encodeWithSelector(ChronosVault.fundRewards.selector, rewardAmount));

        _assertTrue(!ok, "fundRewards should revert when treasury is zero");
        _assertRevertSelector(returndata, ChronosVault.ZeroAddress.selector);
    }

    function testClaimTransfersPendingRewards() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 90 ether;
        uint256 expectedReward = 90 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_90_DAYS());
        vault.fundRewards(rewardAmount);

        uint256 balanceBeforeClaim = token.balanceOf(address(this));
        uint256 claimedReward = vault.claim(positionId);
        uint256 balanceAfterClaim = token.balanceOf(address(this));
        (,,, uint256 rewardDebt,,,) = vault.positions(positionId);

        _assertEq(claimedReward, expectedReward, "unexpected claimed reward");
        _assertEq(balanceAfterClaim - balanceBeforeClaim, expectedReward, "unexpected claim transfer");
        _assertEq(vault.pendingRewards(positionId), 0, "pending rewards should be cleared after claim");
        _assertEq(rewardDebt, expectedReward, "unexpected reward debt after claim");
    }

    function testClaimDoesNotAllowDoubleClaimWindfall() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 90 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_90_DAYS());
        vault.fundRewards(rewardAmount);

        uint256 balanceBeforeFirstClaim = token.balanceOf(address(this));
        uint256 firstClaimedReward = vault.claim(positionId);
        uint256 balanceAfterFirstClaim = token.balanceOf(address(this));
        uint256 secondClaimedReward = vault.claim(positionId);
        uint256 balanceAfterSecondClaim = token.balanceOf(address(this));

        _assertEq(firstClaimedReward, rewardAmount, "unexpected first claim reward");
        _assertEq(balanceAfterFirstClaim - balanceBeforeFirstClaim, rewardAmount, "unexpected first claim transfer");
        _assertEq(secondClaimedReward, 0, "second claim should not pay new rewards");
        _assertEq(balanceAfterSecondClaim, balanceAfterFirstClaim, "second claim should not change balance");
    }

    function testClaimRevertsForUnauthorizedCaller() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        UnauthorizedClaimer claimer = new UnauthorizedClaimer();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 90 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_90_DAYS());
        vault.fundRewards(rewardAmount);

        (bool ok, bytes memory returndata) =
            address(claimer).call(abi.encodeCall(UnauthorizedClaimer.claim, (vault, positionId)));

        _assertTrue(!ok, "claim should revert for unauthorized caller");
        _assertRevertSelector(returndata, ChronosVault.NotPositionOwner.selector);
    }

    function testWithdrawAfterUnlockReturnsPrincipalAndRewards() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 30 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vault.fundRewards(rewardAmount);

        vm.warp(block.timestamp + 30 days);

        uint256 balanceBeforeWithdraw = token.balanceOf(address(this));
        vault.withdraw(positionId);
        uint256 balanceAfterWithdraw = token.balanceOf(address(this));
        (
            address owner,
            uint256 principal,
            uint256 weightedAmount,
            uint256 rewardDebt,
            uint64 unlockTime,
            uint256 tierId,
            bool withdrawn
        ) = vault.positions(positionId);

        _assertEq(
            balanceAfterWithdraw - balanceBeforeWithdraw, stakeAmount + rewardAmount, "unexpected withdraw payout"
        );
        _assertEq(vault.totalPrincipalStaked(), 0, "principal total should be cleared");
        _assertEq(vault.totalWeightedStaked(), 0, "weighted total should be cleared");
        _assertEq(vault.pendingRewards(positionId), 0, "pending rewards should be cleared");
        _assertEq(token.balanceOf(address(vault)), 0, "vault balance should be cleared");
        _assertEq(owner, address(this), "owner should remain as history");
        _assertEq(principal, stakeAmount, "principal should remain as history");
        _assertEq(weightedAmount, 100 ether, "weighted amount should remain as history");
        _assertEq(rewardDebt, rewardAmount, "reward debt should reflect claimed rewards");
        _assertEq(uint256(unlockTime), block.timestamp, "unlock time should match matured tier");
        _assertEq(tierId, vault.TIER_30_DAYS(), "tier id should remain as history");
        _assertTrue(withdrawn, "position should be withdrawn");
    }

    function testWithdrawRevertsBeforeUnlock() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;

        _assertTrue(token.approve(address(vault), stakeAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.withdraw, (positionId)));

        _assertTrue(!ok, "withdraw should revert before unlock");
        _assertRevertSelector(returndata, ChronosVault.PositionNotMatured.selector);
    }

    function testWithdrawRevertsOnSecondCall() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;

        _assertTrue(token.approve(address(vault), stakeAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vm.warp(block.timestamp + 30 days);
        vault.withdraw(positionId);

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.withdraw, (positionId)));

        _assertTrue(!ok, "second withdraw should revert");
        _assertRevertSelector(returndata, ChronosVault.PositionWithdrawn.selector);
    }

    function testStakeCreatesPositionWithExpectedAccounting() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 amount = 100 ether;
        uint256 expectedWeightedAmount = 150 ether;
        uint256 expectedUnlockTime = block.timestamp + 90 days;

        _assertTrue(token.approve(address(vault), amount), "approve should succeed");

        uint256 positionId = vault.stake(amount, vault.TIER_90_DAYS());

        (
            address owner,
            uint256 principal,
            uint256 weightedAmount,
            uint256 rewardDebt,
            uint64 unlockTime,
            uint256 tierId,
            bool withdrawn
        ) = vault.positions(positionId);

        _assertEq(positionId, 0, "unexpected position id");
        _assertEq(owner, address(this), "unexpected position owner");
        _assertEq(principal, amount, "unexpected position principal");
        _assertEq(weightedAmount, expectedWeightedAmount, "unexpected weighted amount");
        _assertEq(rewardDebt, 0, "unexpected reward debt");
        _assertEq(uint256(unlockTime), expectedUnlockTime, "unexpected unlock time");
        _assertEq(tierId, vault.TIER_90_DAYS(), "unexpected tier id");
        _assertTrue(!withdrawn, "position should be active");
        _assertEq(vault.totalPrincipalStaked(), amount, "unexpected total principal");
        _assertEq(vault.totalWeightedStaked(), expectedWeightedAmount, "unexpected total weighted");
        _assertEq(vault.nextPositionId(), 1, "unexpected next position id");
        _assertEq(vault.userPositionIds(address(this), 0), 0, "unexpected user position id");
        _assertEq(token.balanceOf(address(vault)), amount, "unexpected vault token balance");
        _assertEq(token.balanceOf(address(this)), 900 ether, "unexpected staker token balance");
    }

    function testStakeRevertsOnInvalidTier() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 amount = 100 ether;

        _assertTrue(token.approve(address(vault), amount), "approve should succeed");

        (bool ok, bytes memory returndata) =
            address(vault).call(abi.encodeCall(ChronosVault.stake, (amount, uint256(999))));

        _assertTrue(!ok, "stake should revert for invalid tier");
        _assertRevertSelector(returndata, ChronosVault.InvalidTier.selector);
    }

    function testStakeRevertsOnZeroAmount() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();

        _assertTrue(token.approve(address(vault), 1 ether), "approve should succeed");

        (bool ok, bytes memory returndata) =
            address(vault).call(abi.encodeCall(ChronosVault.stake, (uint256(0), vault.TIER_30_DAYS())));

        _assertTrue(!ok, "stake should revert for zero amount");
        _assertRevertSelector(returndata, ChronosVault.InvalidAmount.selector);
    }

    function testStakeSupportsMultiplePositions() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 firstAmount = 25 ether;
        uint256 secondAmount = 40 ether;
        uint256 expectedTotalWeightedAmount = 105 ether;

        _assertTrue(token.approve(address(vault), firstAmount + secondAmount), "approve should succeed");

        uint256 firstPositionId = vault.stake(firstAmount, vault.TIER_30_DAYS());
        uint256 secondPositionId = vault.stake(secondAmount, vault.TIER_180_DAYS());

        _assertEq(firstPositionId, 0, "unexpected first position id");
        _assertEq(secondPositionId, 1, "unexpected second position id");
        _assertPosition(vault, firstPositionId, firstAmount, 25 ether, block.timestamp + 30 days, vault.TIER_30_DAYS());
        _assertPosition(
            vault, secondPositionId, secondAmount, 80 ether, block.timestamp + 180 days, vault.TIER_180_DAYS()
        );
        _assertEq(vault.userPositionIds(address(this), 0), 0, "unexpected first user position id");
        _assertEq(vault.userPositionIds(address(this), 1), 1, "unexpected second user position id");
        _assertEq(vault.nextPositionId(), 2, "unexpected next position id");
        _assertEq(vault.totalPrincipalStaked(), firstAmount + secondAmount, "unexpected total principal");
        _assertEq(vault.totalWeightedStaked(), expectedTotalWeightedAmount, "unexpected total weighted");
        _assertEq(token.balanceOf(address(vault)), firstAmount + secondAmount, "unexpected vault token balance");
    }

    function _deployVault() internal returns (MockERC20 token, ChronosVault vault) {
        token = new MockERC20("Chronos Mock", "CMOCK", address(this), 1_000 ether);
        vault = new ChronosVault(address(token), TREASURY);
    }

    function _deployVaultHarness() internal returns (MockERC20 token, ChronosVaultTreasuryHarness vault) {
        token = new MockERC20("Chronos Mock", "CMOCK", address(this), 1_000 ether);
        vault = new ChronosVaultTreasuryHarness(address(token), TREASURY);
    }

    function _assertPosition(
        ChronosVault vault,
        uint256 positionId,
        uint256 expectedPrincipal,
        uint256 expectedWeightedAmount,
        uint256 expectedUnlockTime,
        uint256 expectedTierId
    ) internal view {
        (
            address owner,
            uint256 principal,
            uint256 weightedAmount,
            uint256 rewardDebt,
            uint64 unlockTime,
            uint256 tierId,
            bool withdrawn
        ) = vault.positions(positionId);

        _assertEq(owner, address(this), "unexpected position owner");
        _assertEq(principal, expectedPrincipal, "unexpected position principal");
        _assertEq(weightedAmount, expectedWeightedAmount, "unexpected position weighted amount");
        _assertEq(rewardDebt, 0, "unexpected position reward debt");
        _assertEq(uint256(unlockTime), expectedUnlockTime, "unexpected position unlock time");
        _assertEq(tierId, expectedTierId, "unexpected position tier id");
        _assertTrue(!withdrawn, "position should be active");
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    function _assertEq(address actual, address expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    function _assertTrue(bool condition, string memory reason) internal pure {
        require(condition, reason);
    }

    function _assertRevertSelector(bytes memory returndata, bytes4 expectedSelector) internal pure {
        require(returndata.length >= 4, "missing revert selector");
        bytes4 actualSelector;
        assembly ("memory-safe") {
            actualSelector := mload(add(returndata, 0x20))
        }
        require(actualSelector == expectedSelector, "unexpected revert selector");
    }
}

contract UnauthorizedClaimer {
    function claim(ChronosVault vault, uint256 positionId) external returns (uint256) {
        return vault.claim(positionId);
    }
}

contract ChronosVaultTreasuryHarness is ChronosVault {
    constructor(address stakingToken_, address treasury_) ChronosVault(stakingToken_, treasury_) {}

    function setTreasuryForTest(address treasury_) external {
        treasury = treasury_;
    }
}
