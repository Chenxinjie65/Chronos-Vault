// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "../lib/openzeppelin-contracts/lib/forge-std/src/Script.sol";
import {console2} from "../lib/openzeppelin-contracts/lib/forge-std/src/console2.sol";

import {ChronosVault} from "../src/ChronosVault.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract DeployChronosVaultScript is Script {
    error MissingTokenConfig();

    function run() external returns (ChronosVault vault, address stakingToken) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address treasury = vm.envAddress("TREASURY");
        address existingToken = vm.envOr("EXISTING_TOKEN", address(0));
        bool deployMock = vm.envOr("DEPLOY_MOCK", existingToken == address(0));
        string memory mockName = vm.envOr("MOCK_NAME", string("Chronos Mock"));
        string memory mockSymbol = vm.envOr("MOCK_SYMBOL", string("CMOCK"));
        uint256 mockInitialSupply = vm.envOr("MOCK_INITIAL_SUPPLY", uint256(1_000_000 ether));

        if (existingToken != address(0)) {
            deployMock = false;
        }

        if (!deployMock && existingToken == address(0)) {
            revert MissingTokenConfig();
        }

        vm.startBroadcast(privateKey);

        if (deployMock) {
            MockERC20 mockToken = new MockERC20(mockName, mockSymbol, deployer, mockInitialSupply);
            stakingToken = address(mockToken);
            console2.log("Mock token deployed:", stakingToken);
            console2.log("Mock token initial holder:", deployer);
        } else {
            stakingToken = existingToken;
            console2.log("Using existing token:", stakingToken);
        }

        vault = new ChronosVault(stakingToken, treasury);

        vm.stopBroadcast();

        console2.log("Chain ID:", block.chainid);
        console2.log("Broadcaster:", deployer);
        console2.log("ChronosVault deployed:", address(vault));
        console2.log("Treasury:", treasury);
    }
}
