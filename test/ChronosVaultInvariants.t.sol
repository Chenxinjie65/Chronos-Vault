// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "../lib/openzeppelin-contracts/lib/forge-std/src/StdInvariant.sol";
import {Test} from "../lib/openzeppelin-contracts/lib/forge-std/src/Test.sol";

import {ChronosVault} from "../src/ChronosVault.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract ChronosVaultHandler is Test {
    ChronosVault internal immutable vault;
    MockERC20 internal immutable token;
    address internal immutable owner;
    address[] internal actors;

    constructor(ChronosVault vault_, MockERC20 token_, address owner_) {
        vault = vault_;
        token = token_;
        owner = owner_;

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA11));

        uint256 actorsLength = actors.length;
        for (uint256 i; i < actorsLength; ++i) {
            address actor = actors[i];
            token.mint(actor, 1_000_000 ether);
            vm.prank(actor);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function stake(uint8 actorSeed, uint96 rawAmount, uint8 tierSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0 || vault.paused() || vault.nextPositionId() >= 24) {
            return;
        }

        uint256 maxStake = balance < 100 ether ? balance : 100 ether;
        uint256 amount = bound(uint256(rawAmount), 1, maxStake);
        uint256 tierId = uint256(tierSeed) % 3;

        vm.prank(actor);
        vault.stake(amount, tierId);
    }

    function fundRewards(uint96 rawAmount) external {
        uint256 balance = token.balanceOf(owner);
        if (balance == 0) {
            return;
        }

        uint256 maxFunding = balance < 100 ether ? balance : 100 ether;
        uint256 amount = bound(uint256(rawAmount), 1, maxFunding);

        vm.prank(owner);
        vault.fundRewards(amount);
    }

    function claim(uint8 actorSeed, uint8 positionSeed) external {
        if (vault.paused() || vault.emergencyMode()) {
            return;
        }

        address actor = actors[actorSeed % actors.length];
        uint256[] memory positionIds = vault.getUserActivePositionIds(actor);
        if (positionIds.length == 0) {
            return;
        }

        uint256 positionId = positionIds[positionSeed % positionIds.length];
        vm.prank(actor);
        vault.claim(positionId);
    }

    function withdraw(uint8 actorSeed, uint8 positionSeed) external {
        if (vault.emergencyMode()) {
            return;
        }

        address actor = actors[actorSeed % actors.length];
        uint256[] memory positionIds = vault.getUserActivePositionIds(actor);
        if (positionIds.length == 0) {
            return;
        }

        uint256 positionId = positionIds[positionSeed % positionIds.length];
        ChronosVault.Position memory position = vault.getPosition(positionId);

        if (vault.paused() && block.timestamp < position.unlockTime) {
            return;
        }

        vm.prank(actor);
        vault.withdraw(positionId);
    }

    function warp(uint32 rawTimeDelta) external {
        uint256 timeDelta = bound(uint256(rawTimeDelta), 1, 7 days);
        vm.warp(block.timestamp + timeDelta);
    }
}

contract ChronosVaultInvariants is StdInvariant, Test {
    address internal constant TREASURY = address(0xBEEF);

    MockERC20 internal token;
    ChronosVault internal vault;
    ChronosVaultHandler internal handler;

    function setUp() public {
        token = new MockERC20("Chronos Mock", "CMOCK", address(this), 10_000_000 ether);
        vault = new ChronosVault(address(token), TREASURY);
        token.approve(address(vault), type(uint256).max);

        handler = new ChronosVaultHandler(vault, token, address(this));
        targetContract(address(handler));
    }

    function invariant_totalsMatchActivePositions() public view {
        uint256 expectedPrincipal;
        uint256 expectedWeighted;
        uint256 totalPositions = vault.nextPositionId();

        for (uint256 positionId; positionId < totalPositions; ++positionId) {
            ChronosVault.Position memory position = vault.getPosition(positionId);
            if (!position.withdrawn) {
                expectedPrincipal += position.principal;
                expectedWeighted += position.weightedAmount;
            }
        }

        assertEq(vault.totalPrincipalStaked(), expectedPrincipal, "principal total should match active positions");
        assertEq(vault.totalWeightedStaked(), expectedWeighted, "weighted total should match active positions");
    }

    function invariant_withdrawnPositionsAreTerminal() public view {
        uint256 totalPositions = vault.nextPositionId();

        for (uint256 positionId; positionId < totalPositions; ++positionId) {
            ChronosVault.Position memory position = vault.getPosition(positionId);
            if (position.withdrawn) {
                (uint256 principalOut, uint256 rewardOut, uint256 penalty) = vault.previewWithdraw(positionId);
                assertEq(vault.pendingRewards(positionId), 0, "withdrawn position should have zero pending rewards");
                assertEq(principalOut, 0, "withdrawn position should preview zero principal");
                assertEq(rewardOut, 0, "withdrawn position should preview zero reward");
                assertEq(penalty, 0, "withdrawn position should preview zero penalty");
            }
        }
    }

    function invariant_vaultBalanceCoversActivePrincipal() public view {
        assertGe(token.balanceOf(address(vault)), vault.totalPrincipalStaked(), "vault should cover active principal");
    }
}
