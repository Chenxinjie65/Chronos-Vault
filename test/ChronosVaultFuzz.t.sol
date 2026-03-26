// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "../lib/openzeppelin-contracts/lib/forge-std/src/Test.sol";

import {ChronosVault} from "../src/ChronosVault.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract ChronosVaultFuzzTest is Test {
    address internal constant TREASURY = address(0xBEEF);

    function testFuzzFundRewardsWithZeroStakersRoutesAllValueToTreasury(uint96 rawRewardAmount) public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 rewardAmount = bound(uint256(rawRewardAmount), 1, 1_000_000 ether);

        token.approve(address(vault), rewardAmount);
        vault.fundRewards(rewardAmount);

        assertEq(vault.accRewardPerWeightedShare(), 0, "accumulator should stay zero");
        assertEq(token.balanceOf(address(vault)), 0, "vault should not retain routed rewards");
        assertEq(token.balanceOf(TREASURY), rewardAmount, "treasury should receive zero-staker rewards");
    }

    function testFuzzEarlyWithdrawLastStakerRoutesPenaltyToTreasury(uint96 rawStakeAmount, uint16 rawPenaltyBps)
        public
    {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = bound(uint256(rawStakeAmount), 1, 1_000_000 ether);
        uint256 penaltyBps = bound(uint256(rawPenaltyBps), 0, vault.MAX_EARLY_EXIT_PENALTY_BPS());
        uint256 expectedPenalty = stakeAmount * penaltyBps / vault.BPS_DENOMINATOR();

        token.approve(address(vault), stakeAmount);
        vault.setEarlyExitPenaltyBps(penaltyBps);

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vault.withdraw(positionId);

        assertEq(token.balanceOf(TREASURY), expectedPenalty, "treasury should receive routed penalty");
        assertEq(vault.totalPrincipalStaked(), 0, "principal total should clear");
        assertEq(vault.totalWeightedStaked(), 0, "weighted total should clear");

        token.approve(address(vault), 1 ether);
        uint256 newPositionId = vault.stake(1 ether, vault.TIER_30_DAYS());
        assertEq(vault.pendingRewards(newPositionId), 0, "future staker should not capture routed penalty");
    }

    function testFuzzEarlyWithdrawPayoutMatchesPreview(
        uint96 rawStakeAmount,
        uint96 rawRewardAmount,
        uint16 rawPenaltyBps
    ) public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = bound(uint256(rawStakeAmount), 1, 500_000 ether);
        uint256 rewardAmount = bound(uint256(rawRewardAmount), 1, 500_000 ether);
        uint256 penaltyBps = bound(uint256(rawPenaltyBps), 0, vault.MAX_EARLY_EXIT_PENALTY_BPS());

        token.approve(address(vault), stakeAmount + rewardAmount);
        vault.setEarlyExitPenaltyBps(penaltyBps);

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_90_DAYS());
        vault.fundRewards(rewardAmount);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);
        uint256 balanceBeforeWithdraw = token.balanceOf(address(this));

        vault.withdraw(positionId);

        uint256 balanceAfterWithdraw = token.balanceOf(address(this));

        assertEq(principalOut + rewardOut, balanceAfterWithdraw - balanceBeforeWithdraw, "preview should match payout");
        assertEq(penalty, stakeAmount * penaltyBps / vault.BPS_DENOMINATOR(), "preview penalty should match config");
        assertEq(vault.pendingRewards(positionId), 0, "withdrawn position should have no pending rewards");
    }

    function testFuzzEmergencyWithdrawMakesPositionTerminal(uint96 rawStakeAmount, uint96 rawRewardAmount) public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = bound(uint256(rawStakeAmount), 1, 500_000 ether);
        uint256 rewardAmount = bound(uint256(rawRewardAmount), 1, 500_000 ether);

        token.approve(address(vault), stakeAmount + rewardAmount);

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_180_DAYS());
        vault.fundRewards(rewardAmount);
        vault.enableEmergencyMode();
        vault.emergencyWithdraw(positionId);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);
        ChronosVault.Position memory position = vault.getPosition(positionId);

        assertTrue(position.withdrawn, "position should be terminal after emergency withdraw");
        assertEq(vault.pendingRewards(positionId), 0, "withdrawn position should not keep rewards");
        assertEq(principalOut, 0, "withdrawn position should preview zero principal");
        assertEq(rewardOut, 0, "withdrawn position should preview zero reward");
        assertEq(penalty, 0, "withdrawn position should preview zero penalty");
    }

    function _deployVault() internal returns (MockERC20 token, ChronosVault vault) {
        token = new MockERC20("Chronos Mock", "CMOCK", address(this), 10_000_000 ether);
        vault = new ChronosVault(address(token), TREASURY);
    }
}
