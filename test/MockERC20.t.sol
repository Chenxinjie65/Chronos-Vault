// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "../contracts/MockERC20.sol";

contract MockERC20Test {
    address internal constant INITIAL_HOLDER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);

    function testConstructorMintAndMetadata() public {
        uint256 initialSupply = 1_000_000 ether;
        MockERC20 token = new MockERC20("Chronos Mock", "CMOCK", INITIAL_HOLDER, initialSupply);

        _assertEq(token.name(), "Chronos Mock", "unexpected name");
        _assertEq(token.symbol(), "CMOCK", "unexpected symbol");
        _assertEqUint8(token.decimals(), 18, "unexpected decimals");
        _assertEq(token.totalSupply(), initialSupply, "unexpected total supply");
        _assertEq(token.balanceOf(INITIAL_HOLDER), initialSupply, "unexpected initial holder balance");
    }

    function testMintIncreasesSupplyAndBalance() public {
        MockERC20 token = new MockERC20("Chronos Mock", "CMOCK", address(this), 0);
        uint256 mintAmount = 25 ether;

        token.mint(RECIPIENT, mintAmount);

        _assertEq(token.totalSupply(), mintAmount, "unexpected total supply after mint");
        _assertEq(token.balanceOf(RECIPIENT), mintAmount, "unexpected recipient balance after mint");
    }

    function testApproveAndTransferFrom() public {
        uint256 initialSupply = 100 ether;
        uint256 approvedAmount = 40 ether;
        uint256 spentAmount = 15 ether;

        MockERC20 token = new MockERC20("Chronos Mock", "CMOCK", address(this), initialSupply);

        _assertTrue(token.approve(address(this), approvedAmount), "approve should succeed");
        _assertTrue(token.transferFrom(address(this), RECIPIENT, spentAmount), "transferFrom should succeed");

        _assertEq(token.balanceOf(address(this)), initialSupply - spentAmount, "unexpected sender balance");
        _assertEq(token.balanceOf(RECIPIENT), spentAmount, "unexpected recipient balance");
        _assertEq(
            token.allowance(address(this), address(this)),
            approvedAmount - spentAmount,
            "unexpected remaining allowance"
        );
    }

    function testMintToZeroAddressReverts() public {
        MockERC20 token = new MockERC20("Chronos Mock", "CMOCK", address(this), 0);

        (bool ok, bytes memory returndata) = address(token).call(abi.encodeCall(MockERC20.mint, (address(0), 1 ether)));

        _assertTrue(!ok, "mint to zero address should revert");
        _assertTrue(returndata.length != 0, "expected revert data");
    }

    function _assertEq(uint256 actual, uint256 expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    function _assertEqUint8(uint8 actual, uint8 expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    function _assertEq(string memory actual, string memory expected, string memory reason) internal pure {
        require(keccak256(bytes(actual)) == keccak256(bytes(expected)), reason);
    }

    function _assertTrue(bool condition, string memory reason) internal pure {
        require(condition, reason);
    }
}
