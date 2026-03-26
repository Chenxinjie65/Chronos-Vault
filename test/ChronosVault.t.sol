// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChronosVault} from "../contracts/ChronosVault.sol";
import {MockERC20} from "../contracts/MockERC20.sol";

contract ChronosVaultTest {
    address internal constant TREASURY = address(0xBEEF);

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
