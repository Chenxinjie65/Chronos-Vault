// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "contracts/MockERC20.sol";

contract MockERC20Test is Test {
    MockERC20 internal token;

    function setUp() external {
        token = new MockERC20("Mock Token", "MOCK", 1_000e18);
    }

    function test_ConstructorMintsInitialSupplyToDeployer() external view {
        assertEq(token.totalSupply(), 1_000e18);
        assertEq(token.balanceOf(address(this)), 1_000e18);
    }

    function test_MintMintsToRecipient() external {
        address recipient = address(0xBEEF);

        token.mint(recipient, 250e18);

        assertEq(token.totalSupply(), 1_250e18);
        assertEq(token.balanceOf(recipient), 250e18);
    }

    function test_MintAllowsZeroAmount() external {
        address recipient = address(0xCAFE);

        token.mint(recipient, 0);

        assertEq(token.balanceOf(recipient), 0);
    }
}
