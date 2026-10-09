// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {MockToken, MockFeed, MockPool} from "./mocks/Mocks.sol";

abstract contract VaultTestBase is Test {
    address internal constant OWNER = 0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3;
    address internal constant GUARDIAN = 0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68;
    address internal alice;
    address internal bob;
    address internal recipient;
    BaskVault internal vault;
    MockToken[3] internal stock;
    MockFeed[3] internal feed;

    function setUp() public virtual {
        vm.warp(1_789_992_000); // Monday, 2026-09-21 12:00 UTC.
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        recipient = makeAddr("feeRecipient");
        vault = new BaskVault(OWNER, GUARDIAN);
        for (uint256 i; i < 3; ++i) {
            stock[i] = new MockToken(18);
            feed[i] = new MockFeed(8, 100e8);
            vm.prank(OWNER);
            vault.listGenesis(address(stock[i]), address(feed[i]), address(0), address(0), 0);
            stock[i].mint(alice, 1_000_000e18);
            stock[i].mint(bob, 1_000_000e18);
            vm.prank(alice);
            stock[i].approve(address(vault), type(uint256).max);
            vm.prank(bob);
            stock[i].approve(address(vault), type(uint256).max);
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
    }

    function _one(address token) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = token;
    }

    function _amount(uint256 amount) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = amount;
    }

    function _deposit(uint256 i, uint256 amount, address who) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(_one(address(stock[i])), _amount(amount), who, 0, vm.getBlockTimestamp());
    }

    function _refresh() internal {
        for (uint256 i; i < 3; ++i) {
            feed[i].set(100e8, vm.getBlockTimestamp());
        }
    }

    function _action(BaskVault.Kind kind, address token) internal pure returns (BaskVault.Action memory a) {
        a.kind = kind;
        a.token = token;
    }

    function _propose(BaskVault.Action memory a) internal returns (uint256 id) {
        vm.prank(OWNER);
        id = vault.propose(a);
    }

    function _execute(uint256 id) internal {
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _refresh();
        vm.prank(OWNER);
        vault.execute(id);
    }

    function _setting(BaskVault.Setting s, uint256 v, uint256 v2) internal {
        BaskVault.Action memory a = _action(BaskVault.Kind.Setting, address(0));
        a.setting = s;
        a.value = v;
        a.value2 = v2;
        _execute(_propose(a));
    }

    function _alwaysOpen() internal {
        _setting(BaskVault.Setting.Hours, 0, 0);
    }

    function _setFee() internal {
        BaskVault.Action memory a = _action(BaskVault.Kind.FeeRecipient, address(0));
        a.target = recipient;
        _execute(_propose(a));
    }

    function _status(address[] memory inputTokens, BaskVault.Reason expected, address fault) internal view {
        (BaskVault.Reason reason, address actualFault) = vault.depositStatus(inputTokens);
        assertEq(uint256(reason), uint256(expected));
        assertEq(actualFault, fault);
    }
}
