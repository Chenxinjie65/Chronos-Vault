// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChronosVault} from "../src/ChronosVault.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

struct Log {
    bytes32[] topics;
    bytes data;
    address emitter;
}

interface Vm {
    function getRecordedLogs() external returns (Log[] memory);

    function recordLogs() external;

    function roll(uint256 newHeight) external;

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

    function testSetEarlyExitPenaltyBpsUpdatesStateAndEmitsEvent() public {
        (, ChronosVault vault) = _deployVault();

        vm.recordLogs();
        vault.setEarlyExitPenaltyBps(vault.MAX_EARLY_EXIT_PENALTY_BPS());
        Log[] memory entries = vm.getRecordedLogs();
        (uint256 oldPenaltyBps, uint256 newPenaltyBps) = abi.decode(entries[0].data, (uint256, uint256));

        _assertEq(vault.earlyExitPenaltyBps(), vault.MAX_EARLY_EXIT_PENALTY_BPS(), "unexpected updated penalty bps");
        _assertEq(entries.length, 1, "expected one penalty update log");
        _assertEq(entries[0].emitter, address(vault), "unexpected penalty update emitter");
        _assertEq(
            uint256(entries[0].topics[0]),
            uint256(keccak256("EarlyExitPenaltyUpdated(uint256,uint256)")),
            "unexpected penalty update topic"
        );
        _assertEq(oldPenaltyBps, vault.DEFAULT_EARLY_EXIT_PENALTY_BPS(), "unexpected old penalty bps");
        _assertEq(newPenaltyBps, vault.MAX_EARLY_EXIT_PENALTY_BPS(), "unexpected new penalty bps");
    }

    function testSetEarlyExitPenaltyBpsRevertsAboveConfiguredCap() public {
        (, ChronosVault vault) = _deployVault();

        (bool ok, bytes memory returndata) = address(vault).call(
            abi.encodeCall(ChronosVault.setEarlyExitPenaltyBps, (vault.MAX_EARLY_EXIT_PENALTY_BPS() + 1))
        );

        _assertTrue(!ok, "penalty update should revert above cap");
        _assertRevertSelector(returndata, ChronosVault.InvalidAmount.selector);
    }

    function testSetEarlyExitPenaltyBpsRevertsForUnauthorizedCaller() public {
        (, ChronosVault vault) = _deployVault();
        VaultUser nonOwner = new VaultUser();

        (bool ok, bytes memory returndata) =
            address(nonOwner).call(abi.encodeCall(VaultUser.setPenaltyBps, (vault, uint256(500))));

        _assertTrue(!ok, "non-owner penalty update should revert");
        _assertRevertSelector(returndata, Ownable.OwnableUnauthorizedAccount.selector);
    }

    function testPreviewWithdrawUsesUpdatedPenaltyBps() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;

        _assertTrue(token.approve(address(vault), stakeAmount), "approve should succeed");

        vault.setEarlyExitPenaltyBps(2_500);
        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());

        (uint256 principalOut,, uint256 penalty) = vault.previewWithdraw(positionId);

        _assertEq(principalOut, 75 ether, "updated penalty should affect preview principal");
        _assertEq(penalty, 25 ether, "updated penalty should affect preview penalty");
    }

    function testSetTreasuryUpdatesStateAndEmitsEvent() public {
        (, ChronosVault vault) = _deployVault();
        address newTreasury = address(0xCAFE);

        vm.recordLogs();
        vault.setTreasury(newTreasury);
        Log[] memory entries = vm.getRecordedLogs();

        _assertEq(vault.treasury(), newTreasury, "unexpected updated treasury");
        _assertEq(entries.length, 1, "expected one treasury update log");
        _assertEq(entries[0].emitter, address(vault), "unexpected treasury update emitter");
        _assertEq(
            uint256(entries[0].topics[0]),
            uint256(keccak256("TreasuryUpdated(address,address)")),
            "unexpected treasury update topic"
        );
        _assertEq(uint256(entries[0].topics[1]), uint256(uint160(TREASURY)), "unexpected old treasury topic");
        _assertEq(uint256(entries[0].topics[2]), uint256(uint160(newTreasury)), "unexpected new treasury topic");
    }

    function testSetTreasuryRevertsForUnauthorizedCaller() public {
        (, ChronosVault vault) = _deployVault();
        VaultUser nonOwner = new VaultUser();

        (bool ok, bytes memory returndata) =
            address(nonOwner).call(abi.encodeCall(VaultUser.setTreasury, (vault, address(0xCAFE))));

        _assertTrue(!ok, "non-owner treasury update should revert");
        _assertRevertSelector(returndata, Ownable.OwnableUnauthorizedAccount.selector);
    }

    function testSetTreasuryRevertsForZeroAddress() public {
        (, ChronosVault vault) = _deployVault();

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.setTreasury, (address(0))));

        _assertTrue(!ok, "treasury update should revert for zero address");
        _assertRevertSelector(returndata, ChronosVault.ZeroAddress.selector);
    }

    function testSetLockTierCanDisableTierAndDisabledTierCannotBeUsed() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();

        vault.setLockTier(vault.TIER_30_DAYS(), 30 days, 1e18, false);
        (,, bool enabled) = vault.lockTiers(vault.TIER_30_DAYS());
        _assertEq(enabled ? 1 : 0, 0, "tier should be disabled");
        _assertTrue(token.approve(address(vault), 1 ether), "approve should succeed");

        (bool ok, bytes memory returndata) =
            address(vault).call(abi.encodeCall(ChronosVault.stake, (1 ether, vault.TIER_30_DAYS())));

        _assertTrue(!ok, "disabled tier should not be usable");
        _assertRevertSelector(returndata, ChronosVault.InvalidTier.selector);
    }

    function testSetLockTierRevertsForZeroDuration() public {
        (, ChronosVault vault) = _deployVault();

        (bool ok, bytes memory returndata) =
            address(vault).call(abi.encodeCall(ChronosVault.setLockTier, (uint256(7), uint64(0), 1e18, true)));

        _assertTrue(!ok, "zero-duration tier should revert");
        _assertRevertSelector(returndata, ChronosVault.InvalidLockTierConfig.selector);
    }

    function testSetLockTierRevertsForZeroWeight() public {
        (, ChronosVault vault) = _deployVault();

        (bool ok, bytes memory returndata) = address(vault).call(
            abi.encodeCall(ChronosVault.setLockTier, (uint256(7), uint64(30 days), uint256(0), true))
        );

        _assertTrue(!ok, "zero-weight tier should revert");
        _assertRevertSelector(returndata, ChronosVault.InvalidLockTierConfig.selector);
    }

    function testSetLockTierRevertsForUnauthorizedCaller() public {
        (, ChronosVault vault) = _deployVault();
        VaultUser nonOwner = new VaultUser();

        (bool ok, bytes memory returndata) = address(nonOwner).call(
            abi.encodeCall(
                VaultUser.setLockTier, (vault, uint256(9), uint64(45 days), uint256(1_250_000_000_000_000_000), true)
            )
        );

        _assertTrue(!ok, "non-owner lock tier update should revert");
        _assertRevertSelector(returndata, Ownable.OwnableUnauthorizedAccount.selector);
    }

    function testEnableEmergencyModeRevertsOnSecondCall() public {
        (, ChronosVault vault) = _deployVault();

        vault.enableEmergencyMode();

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.enableEmergencyMode, ()));

        _assertTrue(!ok, "second emergency mode enable should revert");
        _assertRevertSelector(returndata, ChronosVault.EmergencyModeAlreadyEnabled.selector);
    }

    function testEnableEmergencyModeRevertsForUnauthorizedCaller() public {
        (, ChronosVault vault) = _deployVault();
        VaultUser nonOwner = new VaultUser();

        (bool ok, bytes memory returndata) =
            address(nonOwner).call(abi.encodeCall(VaultUser.enableEmergencyMode, (vault)));

        _assertTrue(!ok, "non-owner emergency mode enable should revert");
        _assertRevertSelector(returndata, Ownable.OwnableUnauthorizedAccount.selector);
    }

    function testGetUserPositionIdsAndGetPositionExposeStoredData() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser secondaryUser = new VaultUser();
        uint256 firstAmount = 50 ether;
        uint256 secondAmount = 60 ether;
        uint256 thirdAmount = 40 ether;
        uint256 expectedSecondUnlockTime = block.timestamp + 90 days;

        token.mint(address(secondaryUser), thirdAmount);
        _assertTrue(token.approve(address(vault), firstAmount + secondAmount), "approve should succeed");
        secondaryUser.approveToken(token, address(vault), thirdAmount);

        uint256 firstPositionId = vault.stake(firstAmount, vault.TIER_30_DAYS());
        uint256 secondPositionId = vault.stake(secondAmount, vault.TIER_90_DAYS());
        uint256 thirdPositionId = secondaryUser.stake(vault, thirdAmount, vault.TIER_180_DAYS());

        uint256[] memory primaryIds = vault.getUserPositionIds(address(this));
        uint256[] memory secondaryIds = vault.getUserPositionIds(address(secondaryUser));
        uint256[] memory emptyIds = vault.getUserPositionIds(address(0xCAFE));
        ChronosVault.Position memory position = vault.getPosition(secondPositionId);

        _assertEq(primaryIds.length, 2, "unexpected primary user position count");
        _assertEq(primaryIds[0], firstPositionId, "unexpected first primary user position id");
        _assertEq(primaryIds[1], secondPositionId, "unexpected second primary user position id");
        _assertEq(secondaryIds.length, 1, "unexpected secondary user position count");
        _assertEq(secondaryIds[0], thirdPositionId, "unexpected secondary user position id");
        _assertEq(emptyIds.length, 0, "empty user should have no positions");

        _assertEq(position.owner, address(this), "unexpected helper position owner");
        _assertEq(position.principal, secondAmount, "unexpected helper position principal");
        _assertEq(position.weightedAmount, 90 ether, "unexpected helper weighted amount");
        _assertEq(position.rewardDebt, 0, "unexpected helper reward debt");
        _assertEq(uint256(position.unlockTime), expectedSecondUnlockTime, "unexpected helper unlock time");
        _assertEq(position.tierId, vault.TIER_90_DAYS(), "unexpected helper tier id");
        _assertTrue(!position.withdrawn, "helper position should be active");
    }

    function testGetLockTierAndGetAllLockTierIdsExposeTierConfiguration() public {
        (, ChronosVault vault) = _deployVault();
        uint256[] memory tierIds = vault.getAllLockTierIds();
        ChronosVault.LockTier memory tier = vault.getLockTier(vault.TIER_90_DAYS());

        _assertEq(tierIds.length, 3, "unexpected tier id count");
        _assertEq(tierIds[0], vault.TIER_30_DAYS(), "unexpected first tier id");
        _assertEq(tierIds[1], vault.TIER_90_DAYS(), "unexpected second tier id");
        _assertEq(tierIds[2], vault.TIER_180_DAYS(), "unexpected third tier id");
        _assertEq(uint256(tier.duration), 90 days, "unexpected tier duration");
        _assertEq(tier.weight, 1_500_000_000_000_000_000, "unexpected tier weight");
        _assertTrue(tier.enabled, "tier should be enabled by default");
    }

    function testGetLockTierReflectsDisabledTierConfiguration() public {
        (, ChronosVault vault) = _deployVault();

        vault.setLockTier(vault.TIER_30_DAYS(), 30 days, 1e18, false);
        ChronosVault.LockTier memory tier = vault.getLockTier(vault.TIER_30_DAYS());

        _assertEq(uint256(tier.duration), 30 days, "unexpected disabled tier duration");
        _assertEq(tier.weight, 1e18, "unexpected disabled tier weight");
        _assertTrue(!tier.enabled, "disabled tier should remain visible through helper");
    }

    function testGetUserActivePositionIdsFiltersWithdrawnPositions() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256[] memory activeIds;
        uint256 firstAmount = 25 ether;
        uint256 secondAmount = 40 ether;

        _assertTrue(token.approve(address(vault), firstAmount + secondAmount), "approve should succeed");

        uint256 firstPositionId = vault.stake(firstAmount, vault.TIER_30_DAYS());
        uint256 secondPositionId = vault.stake(secondAmount, vault.TIER_90_DAYS());

        activeIds = vault.getUserActivePositionIds(address(this));
        _assertEq(activeIds.length, 2, "expected both positions to start active");

        vm.warp(block.timestamp + 30 days);
        vault.withdraw(firstPositionId);

        activeIds = vault.getUserActivePositionIds(address(this));

        _assertEq(activeIds.length, 1, "expected one remaining active position");
        _assertEq(activeIds[0], secondPositionId, "unexpected remaining active position id");
    }

    function testPreviewWithdrawReturnsEarlyWithdrawBreakdown() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 20 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vault.fundRewards(rewardAmount);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);

        _assertEq(principalOut, 90 ether, "unexpected early-withdraw preview principal");
        _assertEq(rewardOut, rewardAmount, "unexpected early-withdraw preview reward");
        _assertEq(penalty, 10 ether, "unexpected early-withdraw preview penalty");
    }

    function testPreviewWithdrawReturnsMaturedBreakdown() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 45 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_90_DAYS());
        uint256 unlockTime = vault.getPosition(positionId).unlockTime;
        vault.fundRewards(rewardAmount);
        vm.warp(unlockTime);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);

        _assertEq(principalOut, stakeAmount, "unexpected matured preview principal");
        _assertEq(rewardOut, rewardAmount, "unexpected matured preview reward");
        _assertEq(penalty, 0, "matured preview should have no penalty");
    }

    function testPreviewWithdrawReturnsEmergencyModeBreakdown() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 30 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_90_DAYS());
        vault.fundRewards(rewardAmount);
        vault.enableEmergencyMode();

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);

        _assertEq(principalOut, stakeAmount, "unexpected emergency preview principal");
        _assertEq(rewardOut, 0, "emergency preview should not expose rewards");
        _assertEq(penalty, 0, "emergency preview should not charge a penalty");
    }

    function testPreviewWithdrawReturnsZeroForMissingAndWithdrawnPositions() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;

        _assertTrue(token.approve(address(vault), stakeAmount), "approve should succeed");

        (uint256 missingPrincipalOut, uint256 missingRewardOut, uint256 missingPenalty) = vault.previewWithdraw(999);
        _assertEq(missingPrincipalOut, 0, "missing position should preview zero principal");
        _assertEq(missingRewardOut, 0, "missing position should preview zero reward");
        _assertEq(missingPenalty, 0, "missing position should preview zero penalty");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vm.warp(block.timestamp + 30 days);
        vault.withdraw(positionId);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);
        _assertEq(principalOut, 0, "withdrawn position should preview zero principal");
        _assertEq(rewardOut, 0, "withdrawn position should preview zero reward");
        _assertEq(penalty, 0, "withdrawn position should preview zero penalty");
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

    function testClaimBatchTransfersCombinedRewardsForMultiplePositions() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 firstAmount = 100 ether;
        uint256 secondAmount = 100 ether;
        uint256 rewardAmount = 50 ether;
        uint256[] memory positionIds = new uint256[](2);

        _assertTrue(token.approve(address(vault), firstAmount + secondAmount + rewardAmount), "approve should succeed");

        positionIds[0] = vault.stake(firstAmount, vault.TIER_30_DAYS());
        positionIds[1] = vault.stake(secondAmount, vault.TIER_90_DAYS());
        vault.fundRewards(rewardAmount);

        uint256 balanceBeforeClaim = token.balanceOf(address(this));
        uint256 totalReward = vault.claimBatch(positionIds);
        uint256 balanceAfterClaim = token.balanceOf(address(this));
        ChronosVault.Position memory firstPosition = vault.getPosition(positionIds[0]);
        ChronosVault.Position memory secondPosition = vault.getPosition(positionIds[1]);

        _assertEq(totalReward, rewardAmount, "unexpected batch claim total");
        _assertEq(balanceAfterClaim - balanceBeforeClaim, rewardAmount, "unexpected batch claim transfer");
        _assertEq(
            vault.pendingRewards(positionIds[0]), 0, "first position should have no pending rewards after batch claim"
        );
        _assertEq(
            vault.pendingRewards(positionIds[1]), 0, "second position should have no pending rewards after batch claim"
        );
        _assertEq(firstPosition.rewardDebt, 20 ether, "unexpected first position reward debt after batch claim");
        _assertEq(secondPosition.rewardDebt, 30 ether, "unexpected second position reward debt after batch claim");
    }

    function testClaimBatchAllowsZeroRewardPositions() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256[] memory positionIds = new uint256[](2);

        _assertTrue(token.approve(address(vault), 210 ether), "approve should succeed");

        positionIds[0] = vault.stake(100 ether, vault.TIER_30_DAYS());
        vault.fundRewards(10 ether);
        positionIds[1] = vault.stake(100 ether, vault.TIER_90_DAYS());

        _assertEq(vault.pendingRewards(positionIds[0]), 10 ether, "first position should have funded rewards");
        _assertEq(vault.pendingRewards(positionIds[1]), 0, "second position should start with zero pending rewards");
        _assertEq(vault.claimBatch(positionIds), 10 ether, "batch claim should allow zero-reward positions");
        _assertEq(vault.pendingRewards(positionIds[0]), 0, "first position should be cleared after batch claim");
        _assertEq(vault.pendingRewards(positionIds[1]), 0, "second position should remain at zero pending rewards");
    }

    function testClaimBatchRevertsForUnauthorizedPosition() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser bob = new VaultUser();
        uint256[] memory positionIds = new uint256[](2);

        token.mint(address(bob), 100 ether);
        _assertTrue(token.approve(address(vault), 110 ether), "approve should succeed");
        bob.approveToken(token, address(vault), 100 ether);

        positionIds[0] = vault.stake(100 ether, vault.TIER_30_DAYS());
        positionIds[1] = bob.stake(vault, 100 ether, vault.TIER_90_DAYS());
        vault.fundRewards(10 ether);

        (bool ok, bytes memory returndata) =
            address(bob).call(abi.encodeCall(VaultUser.claimBatch, (vault, positionIds)));

        _assertTrue(!ok, "batch claim should revert for unauthorized positions");
        _assertRevertSelector(returndata, ChronosVault.NotPositionOwner.selector);
    }

    function testClaimBatchRevertsWhilePaused() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256[] memory positionIds = new uint256[](1);

        _assertTrue(token.approve(address(vault), 110 ether), "approve should succeed");

        positionIds[0] = vault.stake(100 ether, vault.TIER_30_DAYS());
        vault.fundRewards(10 ether);
        vault.pause();

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.claimBatch, (positionIds)));

        _assertTrue(!ok, "batch claim should revert while paused");
        _assertRevertSelector(returndata, Pausable.EnforcedPause.selector);
    }

    function testClaimBatchRevertsDuringEmergencyMode() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256[] memory positionIds = new uint256[](1);

        _assertTrue(token.approve(address(vault), 110 ether), "approve should succeed");

        positionIds[0] = vault.stake(100 ether, vault.TIER_30_DAYS());
        vault.fundRewards(10 ether);
        vault.enableEmergencyMode();

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.claimBatch, (positionIds)));

        _assertTrue(!ok, "batch claim should revert during emergency mode");
        _assertRevertSelector(returndata, ChronosVault.EmergencyModeActive.selector);
    }

    function testMultipleUsersDifferentWeightsAcrossFundingRoundsAccrueExactly() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser bob = new VaultUser();
        VaultUser carol = new VaultUser();

        token.mint(address(bob), 100 ether);
        token.mint(address(carol), 40 ether);

        _assertTrue(token.approve(address(vault), 225 ether), "approve should succeed");
        bob.approveToken(token, address(vault), 100 ether);
        carol.approveToken(token, address(vault), 40 ether);

        uint256 alicePositionId = vault.stake(120 ether, vault.TIER_30_DAYS());
        uint256 bobPositionId = bob.stake(vault, 100 ether, vault.TIER_90_DAYS());
        uint256 carolPositionId = carol.stake(vault, 40 ether, vault.TIER_180_DAYS());

        vault.fundRewards(35 ether);
        vm.warp(block.timestamp + 7 days);
        vault.fundRewards(70 ether);

        _assertEq(vault.pendingRewards(alicePositionId), 36 ether, "unexpected alice pending rewards");
        _assertEq(vault.pendingRewards(bobPositionId), 45 ether, "unexpected bob pending rewards");
        _assertEq(vault.pendingRewards(carolPositionId), 24 ether, "unexpected carol pending rewards");

        uint256 aliceBalanceBeforeClaim = token.balanceOf(address(this));
        _assertEq(vault.claim(alicePositionId), 36 ether, "unexpected alice claim reward");
        _assertEq(token.balanceOf(address(this)) - aliceBalanceBeforeClaim, 36 ether, "unexpected alice claim transfer");
        _assertEq(bob.claim(vault, bobPositionId), 45 ether, "unexpected bob claim reward");
        _assertEq(carol.claim(vault, carolPositionId), 24 ether, "unexpected carol claim reward");
        _assertEq(token.balanceOf(address(bob)), 45 ether, "unexpected bob token balance");
        _assertEq(token.balanceOf(address(carol)), 24 ether, "unexpected carol token balance");
        _assertEq(token.balanceOf(address(vault)), 260 ether, "vault should retain only principal");
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

    function testPausedStakeReverts() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 amount = 100 ether;

        _assertTrue(token.approve(address(vault), amount), "approve should succeed");
        vault.pause();

        (bool ok, bytes memory returndata) =
            address(vault).call(abi.encodeCall(ChronosVault.stake, (amount, vault.TIER_30_DAYS())));

        _assertTrue(!ok, "stake should revert while paused");
        _assertRevertSelector(returndata, Pausable.EnforcedPause.selector);
    }

    function testPausedClaimReverts() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 20 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vault.fundRewards(rewardAmount);
        vault.pause();

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.claim, (positionId)));

        _assertTrue(!ok, "claim should revert while paused");
        _assertRevertSelector(returndata, Pausable.EnforcedPause.selector);
    }

    function testPausedEarlyWithdrawReverts() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;

        _assertTrue(token.approve(address(vault), stakeAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vault.pause();

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.withdraw, (positionId)));

        _assertTrue(!ok, "early withdraw should revert while paused");
        _assertRevertSelector(returndata, Pausable.EnforcedPause.selector);
    }

    function testPausedMaturedWithdrawStillWorks() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 20 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vault.fundRewards(rewardAmount);
        vault.pause();
        vm.warp(block.timestamp + 30 days);

        uint256 balanceBeforeWithdraw = token.balanceOf(address(this));
        vault.withdraw(positionId);
        uint256 balanceAfterWithdraw = token.balanceOf(address(this));

        _assertEq(
            balanceAfterWithdraw - balanceBeforeWithdraw, stakeAmount + rewardAmount, "matured withdraw should work"
        );
        _assertEq(vault.totalPrincipalStaked(), 0, "principal total should be cleared");
        _assertEq(vault.totalWeightedStaked(), 0, "weighted total should be cleared");
    }

    function testPausedBeforeUnlockThenAtUnlockStillAllowsWithdraw() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 20 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        uint256 unlockTime = vault.getPosition(positionId).unlockTime;
        vault.fundRewards(rewardAmount);
        vault.pause();

        vm.warp(unlockTime - 1);

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.withdraw, (positionId)));
        _assertTrue(!ok, "withdraw should still revert while paused before unlock");
        _assertRevertSelector(returndata, Pausable.EnforcedPause.selector);

        vm.warp(unlockTime);

        uint256 balanceBeforeWithdraw = token.balanceOf(address(this));
        vault.withdraw(positionId);
        uint256 balanceAfterWithdraw = token.balanceOf(address(this));

        _assertEq(
            balanceAfterWithdraw - balanceBeforeWithdraw,
            stakeAmount + rewardAmount,
            "withdraw should work once the position matures"
        );
        _assertEq(vault.totalPrincipalStaked(), 0, "principal total should be cleared after paused boundary withdraw");
        _assertEq(vault.totalWeightedStaked(), 0, "weighted total should be cleared after paused boundary withdraw");
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

    function testClaimThenWithdrawOnlyPaysNewRewardsAndPrincipal() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 firstRewardAmount = 20 ether;
        uint256 secondRewardAmount = 30 ether;

        _assertTrue(
            token.approve(address(vault), stakeAmount + firstRewardAmount + secondRewardAmount),
            "approve should succeed"
        );

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        uint256 unlockTime = vault.getPosition(positionId).unlockTime;

        vault.fundRewards(firstRewardAmount);
        _assertEq(vault.claim(positionId), firstRewardAmount, "unexpected first claim reward");
        _assertEq(vault.pendingRewards(positionId), 0, "claimed rewards should be cleared");

        vm.warp(block.timestamp + 10 days);
        vault.fundRewards(secondRewardAmount);
        vm.warp(unlockTime);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);
        uint256 balanceBeforeWithdraw = token.balanceOf(address(this));
        vault.withdraw(positionId);
        uint256 balanceAfterWithdraw = token.balanceOf(address(this));
        ChronosVault.Position memory position = vault.getPosition(positionId);

        _assertEq(principalOut, stakeAmount, "unexpected preview principal after prior claim");
        _assertEq(rewardOut, secondRewardAmount, "unexpected preview reward after prior claim");
        _assertEq(penalty, 0, "matured withdraw should not preview a penalty");
        _assertEq(
            balanceAfterWithdraw - balanceBeforeWithdraw,
            stakeAmount + secondRewardAmount,
            "withdraw should pay principal plus only unclaimed rewards"
        );
        _assertEq(
            position.rewardDebt,
            firstRewardAmount + secondRewardAmount,
            "reward debt should track total claimed rewards"
        );
        _assertTrue(position.withdrawn, "position should be withdrawn after claim then withdraw");
    }

    function testEarlyWithdrawDeductsPenalty() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser exiter = new VaultUser();
        uint256 stakeAmount = 100 ether;
        uint256 expectedPenalty = 10 ether;

        token.mint(address(exiter), stakeAmount);
        exiter.approveToken(token, address(vault), stakeAmount);

        uint256 positionId = exiter.stake(vault, stakeAmount, vault.TIER_30_DAYS());
        exiter.withdraw(vault, positionId);

        _assertEq(token.balanceOf(address(exiter)), stakeAmount - expectedPenalty, "unexpected early withdraw payout");
        _assertEq(token.balanceOf(TREASURY), expectedPenalty, "penalty should route to treasury for last staker");
        _assertEq(vault.totalPrincipalStaked(), 0, "principal total should be cleared");
        _assertEq(vault.totalWeightedStaked(), 0, "weighted total should be cleared");
        _assertEq(vault.pendingRewards(positionId), 0, "withdrawn position should have no pending rewards");
    }

    function testWithdrawExactlyAtUnlockAvoidsPenalty() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser exiter = new VaultUser();
        uint256 stakeAmount = 100 ether;

        token.mint(address(exiter), stakeAmount);
        exiter.approveToken(token, address(vault), stakeAmount);

        uint256 positionId = exiter.stake(vault, stakeAmount, vault.TIER_30_DAYS());
        uint256 unlockTime = vault.getPosition(positionId).unlockTime;

        vm.warp(unlockTime);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);
        exiter.withdraw(vault, positionId);

        _assertEq(principalOut, stakeAmount, "principal should be fully withdrawable at unlock");
        _assertEq(rewardOut, 0, "unexpected reward at exact unlock");
        _assertEq(penalty, 0, "penalty should be zero at exact unlock");
        _assertEq(token.balanceOf(address(exiter)), stakeAmount, "exact unlock should avoid the early-exit penalty");
        _assertEq(token.balanceOf(TREASURY), 0, "treasury should not receive a penalty at unlock");
    }

    function testWithdrawJustBeforeUnlockStillAppliesPenalty() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser exiter = new VaultUser();
        uint256 stakeAmount = 100 ether;

        token.mint(address(exiter), stakeAmount);
        exiter.approveToken(token, address(vault), stakeAmount);

        uint256 positionId = exiter.stake(vault, stakeAmount, vault.TIER_30_DAYS());
        uint256 unlockTime = vault.getPosition(positionId).unlockTime;

        vm.warp(unlockTime - 1);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);
        exiter.withdraw(vault, positionId);

        _assertEq(principalOut, 90 ether, "principal should still be penalized before unlock");
        _assertEq(rewardOut, 0, "unexpected reward before unlock");
        _assertEq(penalty, 10 ether, "expected early-withdraw penalty before unlock");
        _assertEq(
            token.balanceOf(address(exiter)), 90 ether, "withdraw just before unlock should pay principal minus penalty"
        );
        _assertEq(token.balanceOf(TREASURY), 10 ether, "treasury should receive the last-staker penalty");
    }

    function testRollingBlocksWithoutWarpDoesNotMaturePosition() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser exiter = new VaultUser();
        uint256 stakeAmount = 100 ether;

        token.mint(address(exiter), stakeAmount);
        exiter.approveToken(token, address(vault), stakeAmount);

        uint256 positionId = exiter.stake(vault, stakeAmount, vault.TIER_30_DAYS());
        vm.roll(block.number + 500);

        (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);
        exiter.withdraw(vault, positionId);

        _assertEq(principalOut, 90 ether, "rolling blocks alone should not mature the position");
        _assertEq(rewardOut, 0, "unexpected reward after block roll only");
        _assertEq(penalty, 10 ether, "block roll only should still preview the early penalty");
        _assertEq(token.balanceOf(address(exiter)), 90 ether, "block roll only should still incur the early penalty");
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

    function testEarlyWithdrawRedistributesPenaltyToRemainingStaker() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser exiter = new VaultUser();
        uint256 stakeAmount = 100 ether;
        uint256 expectedPenalty = 10 ether;

        token.mint(address(exiter), stakeAmount);
        _assertTrue(token.approve(address(vault), stakeAmount), "approve should succeed");
        exiter.approveToken(token, address(vault), stakeAmount);

        uint256 remainingPositionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        uint256 exitingPositionId = exiter.stake(vault, stakeAmount, vault.TIER_30_DAYS());

        exiter.withdraw(vault, exitingPositionId);

        _assertEq(vault.pendingRewards(remainingPositionId), expectedPenalty, "remaining staker should receive penalty");
        _assertEq(token.balanceOf(TREASURY), 0, "treasury should not receive redistributed penalty");
        _assertEq(
            token.balanceOf(address(exiter)),
            stakeAmount - expectedPenalty,
            "exiter should only receive principal minus penalty"
        );
    }

    function testEarlyWithdrawExiterDoesNotReceiveOwnPenaltyBack() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser exiter = new VaultUser();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 20 ether;

        token.mint(address(exiter), stakeAmount);
        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");
        exiter.approveToken(token, address(vault), stakeAmount);

        uint256 remainingPositionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        uint256 exitingPositionId = exiter.stake(vault, stakeAmount, vault.TIER_30_DAYS());

        vault.fundRewards(rewardAmount);
        exiter.withdraw(vault, exitingPositionId);

        _assertEq(
            token.balanceOf(address(exiter)),
            stakeAmount,
            "exiter should receive principal minus penalty plus pre-existing rewards only"
        );

        uint256 claimedReward = vault.claim(remainingPositionId);
        _assertEq(claimedReward, 20 ether, "remaining staker should receive funded rewards plus redistributed penalty");
    }

    function testEarlyWithdrawRoutesLastStakerPenaltyToTreasury() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser exiter = new VaultUser();
        uint256 stakeAmount = 100 ether;
        uint256 expectedPenalty = 10 ether;

        token.mint(address(exiter), stakeAmount);
        exiter.approveToken(token, address(vault), stakeAmount);

        uint256 positionId = exiter.stake(vault, stakeAmount, vault.TIER_30_DAYS());
        exiter.withdraw(vault, positionId);

        _assertEq(token.balanceOf(TREASURY), expectedPenalty, "treasury should receive last-staker penalty");
        _assertEq(vault.totalWeightedStaked(), 0, "weighted total should be zero after last staker exits");

        _assertTrue(token.approve(address(vault), 10 ether), "approve should succeed");
        uint256 newPositionId = vault.stake(10 ether, vault.TIER_30_DAYS());
        _assertEq(vault.pendingRewards(newPositionId), 0, "future staker should not capture routed penalty");
    }

    function testEmergencyWithdrawReturnsPrincipalOnly() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 20 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vault.fundRewards(rewardAmount);
        vault.enableEmergencyMode();

        uint256 balanceBeforeWithdraw = token.balanceOf(address(this));
        vault.emergencyWithdraw(positionId);
        uint256 balanceAfterWithdraw = token.balanceOf(address(this));

        _assertEq(
            balanceAfterWithdraw - balanceBeforeWithdraw, stakeAmount, "emergency withdraw should return principal"
        );
        _assertEq(vault.pendingRewards(positionId), 0, "withdrawn position should have no pending rewards");
        _assertEq(token.balanceOf(TREASURY), rewardAmount, "forfeited rewards should route to treasury for last staker");
    }

    function testEmergencyWithdrawRedistributesForfeitedRewards() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        VaultUser exiter = new VaultUser();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 20 ether;

        token.mint(address(exiter), stakeAmount);
        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");
        exiter.approveToken(token, address(vault), stakeAmount);

        uint256 remainingPositionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        uint256 exitingPositionId = exiter.stake(vault, stakeAmount, vault.TIER_30_DAYS());

        vault.fundRewards(rewardAmount);
        vault.enableEmergencyMode();
        exiter.emergencyWithdraw(vault, exitingPositionId);

        _assertEq(token.balanceOf(address(exiter)), stakeAmount, "emergency withdraw should not pay rewards");
        _assertEq(vault.pendingRewards(remainingPositionId), rewardAmount, "remaining staker should receive forfeited");
        _assertEq(token.balanceOf(TREASURY), 0, "treasury should not receive redistributed forfeited rewards");
    }

    function testEmergencyWithdrawIgnoresLock() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;

        _assertTrue(token.approve(address(vault), stakeAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_180_DAYS());
        vault.enableEmergencyMode();

        uint256 balanceBeforeWithdraw = token.balanceOf(address(this));
        vault.emergencyWithdraw(positionId);
        uint256 balanceAfterWithdraw = token.balanceOf(address(this));

        _assertEq(balanceAfterWithdraw - balanceBeforeWithdraw, stakeAmount, "emergency withdraw should bypass lock");
        _assertEq(vault.totalPrincipalStaked(), 0, "principal total should be cleared");
        _assertEq(vault.totalWeightedStaked(), 0, "weighted total should be cleared");
    }

    function testClaimRevertsDuringEmergencyMode() public {
        (MockERC20 token, ChronosVault vault) = _deployVault();
        uint256 stakeAmount = 100 ether;
        uint256 rewardAmount = 20 ether;

        _assertTrue(token.approve(address(vault), stakeAmount + rewardAmount), "approve should succeed");

        uint256 positionId = vault.stake(stakeAmount, vault.TIER_30_DAYS());
        vault.fundRewards(rewardAmount);
        vault.enableEmergencyMode();

        (bool ok, bytes memory returndata) = address(vault).call(abi.encodeCall(ChronosVault.claim, (positionId)));

        _assertTrue(!ok, "claim should revert during emergency mode");
        _assertRevertSelector(returndata, ChronosVault.EmergencyModeActive.selector);
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

contract VaultUser {
    function approveToken(MockERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function enableEmergencyMode(ChronosVault vault) external {
        vault.enableEmergencyMode();
    }

    function claim(ChronosVault vault, uint256 positionId) external returns (uint256) {
        return vault.claim(positionId);
    }

    function claimBatch(ChronosVault vault, uint256[] memory positionIds) external returns (uint256) {
        return vault.claimBatch(positionIds);
    }

    function setLockTier(ChronosVault vault, uint256 tierId, uint64 duration, uint256 weight, bool enabled) external {
        vault.setLockTier(tierId, duration, weight, enabled);
    }

    function setPenaltyBps(ChronosVault vault, uint256 newPenaltyBps) external {
        vault.setEarlyExitPenaltyBps(newPenaltyBps);
    }

    function setTreasury(ChronosVault vault, address newTreasury) external {
        vault.setTreasury(newTreasury);
    }

    function stake(ChronosVault vault, uint256 amount, uint256 tierId) external returns (uint256) {
        return vault.stake(amount, tierId);
    }

    function withdraw(ChronosVault vault, uint256 positionId) external {
        vault.withdraw(positionId);
    }

    function emergencyWithdraw(ChronosVault vault, uint256 positionId) external {
        vault.emergencyWithdraw(positionId);
    }
}

contract ChronosVaultTreasuryHarness is ChronosVault {
    constructor(address stakingToken_, address treasury_) ChronosVault(stakingToken_, treasury_) {}

    function setTreasuryForTest(address treasury_) external {
        treasury = treasury_;
    }
}
