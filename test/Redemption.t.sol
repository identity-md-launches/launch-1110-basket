// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {BaskVault} from "../src/BaskVault.sol";

contract RedemptionTest is VaultTestBase {
    function testTokenImplementationDisappearsAfterDeposit() public {
        _deposit(0, 10e18, alice);
        vm.etch(address(stock[0]), hex"");
        vm.prank(alice);
        uint256[] memory amounts = vault.redeem(500e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(amounts[0], 5e18);
        assertEq(vault.owed(bob, address(stock[0])), 5e18);
    }

    function testEveryPauseAndRoleRestrictionLeavesRedemptionAndClaimOpen() public {
        uint256 shares = _deposit(0, 10e18, alice);
        vm.prank(OWNER);
        vault.lowerNAVCap(0);
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        vm.prank(GUARDIAN);
        vault.close(address(stock[0]));
        stock[0].setPaused(true);
        stock[0].setTransferMode(1);
        feed[0].setMode(2);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(shares, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(vault.owed(bob, address(stock[0])), legs[0]);
        stock[0].setTransferMode(0);
        uint256 before = stock[0].balanceOf(alice);
        vm.prank(bob);
        vault.claim(_one(address(stock[0])), alice);
        assertEq(stock[0].balanceOf(alice) - before, legs[0]);
        assertEq(vault.totalOwed(address(stock[0])), 0);
    }

    function testFuzzBrokenTransferRollsBackAndBecomesOwed(uint8 rawMode) public {
        uint256 mode = bound(rawMode, 1, 6);
        if (mode == 4) mode = 5; // No-return transfers are valid, covered separately.
        uint256 shares = _deposit(0, 10e18, alice);
        uint256 before = stock[0].balanceOf(bob);
        stock[0].setTransferMode(mode);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(shares, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(stock[0].balanceOf(bob), before);
        assertEq(vault.owed(bob, address(stock[0])), legs[0]);
        assertEq(vault.managed(address(stock[0])) + vault.totalOwed(address(stock[0])), 10e18);
    }

    function testNoReturnAndLargeReturnTransfersPayDirectly() public {
        _deposit(0, 10e18, alice);
        _deposit(1, 10e18, alice);
        stock[0].setTransferMode(4);
        stock[1].setTransferMode(7);
        stock[1].setBalanceMode(4);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(1000e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], 5e18);
        assertEq(legs[1], 5e18);
        assertEq(vault.totalOwed(address(stock[0])), 0);
        assertEq(vault.totalOwed(address(stock[1])), 0);
    }

    function testUnreadableUpgradedBalanceUsesManagedAndDoesNotTouchOracle() public {
        _deposit(0, 10e18, alice);
        stock[0].setBalanceMode(2);
        feed[0].setMode(2);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(500e18, alice, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], 5e18);
        assertEq(vault.owed(alice, address(stock[0])), 5e18);
        stock[0].setBalanceMode(3);
        vm.prank(alice);
        legs = vault.redeem(100e18, alice, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], 1e18);
        assertEq(vault.owed(alice, address(stock[0])), 6e18);
    }

    function testShortRedemptionNeverWritesDownResidualManaged() public {
        _deposit(0, 10e18, alice);
        stock[0].confiscate(address(vault), 4e18);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(500e18, alice, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], 3e18);
        assertEq(vault.managed(address(stock[0])), 7e18);
        assertEq(stock[0].balanceOf(address(vault)), 3e18);
    }

    function testQueuedDebtExcludedFromRedemptionResyncAndDeposits() public {
        _alwaysOpen();
        _setting(BaskVault.Setting.DirectLimit, 0, 0);
        _deposit(0, 10e18, alice);
        vm.prank(alice);
        vault.redeem(500e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(vault.totalOwed(address(stock[0])), 5e18);
        _execute(_propose(_action(BaskVault.Kind.Resync, address(stock[0]))));
        assertEq(vault.managed(address(stock[0])), 5e18);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(100e18, alice, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], 1e18);
        stock[0].confiscate(address(vault), 5e18);
        _status(_one(address(stock[0])), BaskVault.Reason.Short, address(stock[0]));
        vault.flagDeficit(address(stock[0]));
        (uint256 loss,) = vault.deficits(address(stock[0]));
        assertEq(loss, 4e18);
    }

    function testPartialClaimUsesBalanceAndCanRedirectReceiver() public {
        _setting(BaskVault.Setting.DirectLimit, 0, 0);
        _deposit(0, 10e18, alice);
        vm.prank(alice);
        vault.redeem(900e18, bob, new uint256[](0), vm.getBlockTimestamp());
        stock[0].confiscate(address(vault), 6e18);
        uint256 before = stock[0].balanceOf(alice);
        vm.prank(bob);
        vault.claim(_one(address(stock[0])), alice);
        assertEq(stock[0].balanceOf(alice) - before, 4e18);
        assertEq(vault.owed(bob, address(stock[0])), 5e18);
        assertEq(vault.totalOwed(address(stock[0])), 5e18);
        stock[0].mint(address(vault), 5e18);
        vm.prank(bob);
        vault.claim(_one(address(stock[0])), alice);
        assertEq(vault.totalOwed(address(stock[0])), 0);
    }

    function testClaimHasNoPayGasLimitAndFailedClaimKeepsDebt() public {
        uint256 shares = _deposit(0, 10e18, alice);
        stock[0].setTransferMode(8);
        vm.prank(alice);
        vault.redeem(shares, bob, new uint256[](0), vm.getBlockTimestamp());
        uint256 debt = vault.owed(bob, address(stock[0]));
        assertGt(debt, 0);
        stock[0].setTransferMode(3);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.PaymentFailed.selector, address(stock[0])));
        vault.claim(_one(address(stock[0])), bob);
        assertEq(vault.owed(bob, address(stock[0])), debt);
        stock[0].setTransferMode(8);
        vm.prank(bob);
        vault.claim(_one(address(stock[0])), bob);
        assertEq(vault.owed(bob, address(stock[0])), 0);
    }

    function testRoleCannotUseBalanceGasOrPayGasToBlockClaim() public {
        _alwaysOpen();
        _setting(BaskVault.Setting.DirectLimit, 0, 0);
        _setting(BaskVault.Setting.BalanceGas, 20_000, 0);
        _setting(BaskVault.Setting.PayGas, 20_000, 0);
        _deposit(0, 10e18, alice);
        stock[0].setBalanceMode(6);
        vm.prank(alice);
        vault.redeem(500e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(vault.owed(bob, address(stock[0])), 5e18);
        vm.prank(bob);
        vault.claim(_one(address(stock[0])), bob);
        assertEq(vault.owed(bob, address(stock[0])), 0);
    }

    function testReentrancyOnPullPaymentAndClaimAndPayOnlySelf() public {
        bytes memory data = abi.encodeCall(vault.redeem, (0, bob, new uint256[](0), vm.getBlockTimestamp()));
        stock[0].setCallback(address(vault), data);
        _deposit(0, 10e18, alice);
        assertFalse(stock[0].callbackSucceeded());
        vm.prank(alice);
        vault.redeem(100e18, alice, new uint256[](0), vm.getBlockTimestamp());
        assertFalse(stock[0].callbackSucceeded());
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.pay(address(stock[0]), bob, 1e18);
        stock[0].setTransferMode(1);
        vm.prank(alice);
        vault.redeem(100e18, alice, new uint256[](0), vm.getBlockTimestamp());
        stock[0].setTransferMode(0);
        stock[0].setCallback(address(vault), abi.encodeCall(vault.claim, (_one(address(stock[0])), alice)));
        vm.prank(alice);
        vault.claim(_one(address(stock[0])), alice);
        assertFalse(stock[0].callbackSucceeded());
    }

    function testRedemptionCallerInputsAndMinimumsIncludingZeroManagedLeg() public {
        _deposit(0, 10e18, alice);
        vm.startPrank(alice);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.redeem(1, address(0), new uint256[](0), vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.Deadline.selector);
        vault.redeem(1, alice, new uint256[](0), vm.getBlockTimestamp() - 1);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(1, alice, _amount(1), vm.getBlockTimestamp());
        uint256[] memory minima = new uint256[](3);
        minima[2] = 1;
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(100e18, alice, minima, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InsufficientBalance.selector);
        vault.redeem(1000e18, alice, new uint256[](0), vm.getBlockTimestamp());
        vm.stopPrank();
        assertEq(vault.totalSupply(), 1000e18);
    }
}
