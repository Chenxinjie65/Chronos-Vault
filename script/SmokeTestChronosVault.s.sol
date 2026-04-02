// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "../lib/openzeppelin-contracts/lib/forge-std/src/Script.sol";
import {console2} from "../lib/openzeppelin-contracts/lib/forge-std/src/console2.sol";

import {ChronosVault} from "../src/ChronosVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SmokeTestChronosVaultScript is Script {
    struct SmokeConfig {
        uint256 privateKey;
        address deployer;
        uint256 expectedChainId;
        address vaultAddress;
        address expectedToken;
        address expectedTreasury;
        uint256 stakeAmount;
        uint256 rewardAmount;
        uint256 tierId;
    }

    struct SmokeResult {
        uint256 positionId;
        uint256 principalOut;
        uint256 rewardOut;
        uint256 penalty;
    }

    error InsufficientTokenBalance(uint256 required, uint256 available);
    error UnexpectedChain(uint256 expected, uint256 actual);
    error UnexpectedOwner(address expected, address actual);
    error UnexpectedStakingToken(address expected, address actual);
    error UnexpectedTreasury(address expected, address actual);
    error UnexpectedPositionId(uint256 expected, uint256 actual);
    error UnexpectedReward(uint256 expected, uint256 actual);
    error ClaimBalanceMismatch(uint256 expected, uint256 actual);

    function run() external {
        SmokeConfig memory config = _loadConfig();
        _validateSetup(config);

        SmokeResult memory result = _executeSmokeTest(config);

        console2.log("Smoke test passed on chain:", block.chainid);
        console2.log("Vault:", config.vaultAddress);
        console2.log("Token:", config.expectedToken);
        console2.log("Deployer:", config.deployer);
        console2.log("Position ID:", result.positionId);
        console2.log("Stake amount:", config.stakeAmount);
        console2.log("Reward funded and claimed:", config.rewardAmount);
        console2.log("Preview principal out:", result.principalOut);
        console2.log("Preview reward out:", result.rewardOut);
        console2.log("Preview early-exit penalty:", result.penalty);
    }

    function _loadConfig() internal view returns (SmokeConfig memory config) {
        config.privateKey = vm.envUint("PRIVATE_KEY");
        config.deployer = vm.addr(config.privateKey);
        config.expectedChainId = vm.envOr("SMOKE_EXPECTED_CHAIN_ID", uint256(11155111));
        config.vaultAddress = vm.envAddress("SEPOLIA_VAULT_ADDRESS");
        config.expectedToken = vm.envAddress("SEPOLIA_STAKING_TOKEN_ADDRESS");
        config.expectedTreasury = vm.envAddress("TREASURY");
        config.stakeAmount = vm.envOr("SMOKE_STAKE_AMOUNT", uint256(100 ether));
        config.rewardAmount = vm.envOr("SMOKE_REWARD_AMOUNT", uint256(10 ether));
        config.tierId = vm.envOr("SMOKE_TIER_ID", uint256(0));
    }

    function _validateSetup(SmokeConfig memory config) internal view {
        if (block.chainid != config.expectedChainId) {
            revert UnexpectedChain(config.expectedChainId, block.chainid);
        }

        ChronosVault vault = ChronosVault(config.vaultAddress);
        if (vault.owner() != config.deployer) {
            revert UnexpectedOwner(config.deployer, vault.owner());
        }
        if (address(vault.stakingToken()) != config.expectedToken) {
            revert UnexpectedStakingToken(config.expectedToken, address(vault.stakingToken()));
        }
        if (vault.treasury() != config.expectedTreasury) {
            revert UnexpectedTreasury(config.expectedTreasury, vault.treasury());
        }

        uint256 totalRequired = config.stakeAmount + config.rewardAmount;
        uint256 deployerBalance = IERC20(config.expectedToken).balanceOf(config.deployer);
        if (deployerBalance < totalRequired) {
            revert InsufficientTokenBalance(totalRequired, deployerBalance);
        }
    }

    function _executeSmokeTest(SmokeConfig memory config) internal returns (SmokeResult memory result) {
        ChronosVault vault = ChronosVault(config.vaultAddress);
        IERC20 token = IERC20(config.expectedToken);
        uint256 totalRequired = config.stakeAmount + config.rewardAmount;
        uint256 expectedPositionId = vault.nextPositionId();

        vm.startBroadcast(config.privateKey);

        token.approve(config.vaultAddress, totalRequired);

        result.positionId = vault.stake(config.stakeAmount, config.tierId);
        if (result.positionId != expectedPositionId) {
            revert UnexpectedPositionId(expectedPositionId, result.positionId);
        }

        vault.fundRewards(config.rewardAmount);

        uint256 pendingBeforeClaim = vault.pendingRewards(result.positionId);
        if (pendingBeforeClaim != config.rewardAmount) {
            revert UnexpectedReward(config.rewardAmount, pendingBeforeClaim);
        }

        uint256 balanceBeforeClaim = token.balanceOf(config.deployer);
        uint256 claimed = vault.claim(result.positionId);
        uint256 balanceAfterClaim = token.balanceOf(config.deployer);

        vm.stopBroadcast();

        if (claimed != config.rewardAmount) {
            revert UnexpectedReward(config.rewardAmount, claimed);
        }

        uint256 expectedBalanceAfterClaim = balanceBeforeClaim + config.rewardAmount;
        if (balanceAfterClaim != expectedBalanceAfterClaim) {
            revert ClaimBalanceMismatch(expectedBalanceAfterClaim, balanceAfterClaim);
        }

        (result.principalOut, result.rewardOut, result.penalty) = vault.previewWithdraw(result.positionId);
    }
}
