// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

contract BaskVaultTest is VaultTestBase {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function testStandardTransferEventTopic() public {
        _deposit(0, 1e18, alice);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Transfer(alice, bob, 1e18);
        vm.prank(alice);
        vault.transfer(bob, 1e18);
    }

    function testDeploymentDefaultsAndRuntime() public view {
        assertEq(vault.name(), "Basket");
        assertEq(vault.symbol(), "BASK");
        assertEq(vault.decimals(), 18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.owner(), OWNER);
        assertEq(vault.guardian(), GUARDIAN);
        assertEq(vault.NAV_CAP(), 1_000_000e18);
        assertLe(address(vault).code.length, 24576);
        BaskVault.Settings memory c = vault.settings();
        assertEq(c.band, 4);
        assertEq(c.maxAge, 80 hours);
        assertEq(c.noPoolAge, 26 hours);
        assertEq(c.maxAssets, 250);
        assertEq(c.directLimit, 50);
        bytes memory code = address(vault).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testConstructorRoles() public {
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(address(0), GUARDIAN);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(OWNER, address(0));
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(OWNER, OWNER);
    }

    function testDepositMintPreviewDonationAndRedeem() public {
        (uint256 preview, uint256 fee, uint256 v, uint256 nav) =
            vault.previewDeposit(_one(address(stock[0])), _amount(10e18));
        assertEq(preview, 1000e18 - 1e15);
        assertEq(fee, 0);
        assertEq(v, 1000e18);
        assertEq(nav, 0);
        uint256 shares = _deposit(0, 10e18, alice);
        assertEq(shares, preview);
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.totalSupply(), 1000e18);
        assertEq(vault.managed(address(stock[0])), 10e18);
        stock[0].mint(address(vault), 90e18);
        assertEq(_deposit(1, 10e18, bob), 1000e18);
        (uint256[] memory expected,, bool direct) = vault.previewRedeem(shares);
        assertTrue(direct);
        uint256 before = stock[0].balanceOf(alice);
        vm.prank(alice);
        uint256[] memory actual = vault.redeem(shares, alice, expected, vm.getBlockTimestamp());
        assertEq(actual, expected);
        assertEq(stock[0].balanceOf(alice) - before, expected[0]);
        assertEq(stock[0].balanceOf(address(vault)), vault.managed(address(stock[0])) + 90e18);
    }

    function testFeeRoundingMintTransferAndBurn() public {
        _alwaysOpen();
        _setFee();
        uint256 gross = 10e18 * 100;
        uint256 shares = _deposit(0, 10e18, alice);
        assertEq(shares, gross - gross / 200 - 1e15);
        assertEq(vault.balanceOf(recipient), gross / 200);
        assertEq(_deposit(0, 1, alice), 99);
        assertEq(vault.balanceOf(recipient), gross / 200 + 1);
        uint256 beforeSupply = vault.totalSupply();
        uint256 tiny = 201;
        (uint256[] memory legs, uint256 fee,) = vault.previewRedeem(tiny);
        assertEq(fee, 2);
        vm.prank(alice);
        vault.redeem(tiny, alice, legs, vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), beforeSupply - 199);
        assertEq(vault.balanceOf(recipient), gross / 200 + 3);
        vm.prank(alice);
        vault.redeem(1, alice, new uint256[](0), vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), beforeSupply - 199);
    }

    function testDepositSlippageDeadlinesAndExactPull() public {
        address[] memory ts = _one(address(stock[0]));
        uint256[] memory amts = _amount(1e18);
        vm.startPrank(alice);
        vm.expectRevert(BaskVault.Deadline.selector);
        vault.deposit(ts, amts, alice, 0, vm.getBlockTimestamp() - 1);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.deposit(ts, amts, alice, 101e18, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.deposit(ts, amts, address(vault), 0, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.deposit(ts, _amount(0), alice, 0, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.deposit(ts, new uint256[](0), alice, 0, vm.getBlockTimestamp());
        vm.stopPrank();
        stock[0].setTaxPull(true);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.PaymentFailed.selector, address(stock[0])));
        _deposit(0, 1e18, alice);
        assertEq(vault.totalSupply(), 0);
        assertEq(stock[0].balanceOf(address(vault)), 0);
        stock[0].setTaxPull(false);
        vm.expectRevert(BaskVault.Slippage.selector);
        _deposit(0, 1, alice);
    }

    function testCapNoShareSupplyCap() public {
        vm.prank(OWNER);
        vault.lowerNAVCap(1000e18);
        _deposit(0, 10e18, alice);
        vm.expectRevert(BaskVault.CapExceeded.selector);
        _deposit(0, 1, alice);
        vm.prank(alice);
        vault.redeem(500e18, alice, new uint256[](0), vm.getBlockTimestamp());
        _deposit(1, 5e18, bob);
        assertEq(vault.totalSupply(), 1000e18);
    }

    function testShareERC20() public {
        _deposit(0, 10e18, alice);
        vm.prank(alice);
        vault.approve(bob, 100e18);
        vm.prank(bob);
        vault.transferFrom(alice, bob, 100e18);
        assertEq(vault.allowance(alice, bob), 0);
        vm.prank(bob);
        vault.transfer(alice, 1e18);
        vm.prank(bob);
        vm.expectRevert(BaskVault.InsufficientAllowance.selector);
        vault.transferFrom(alice, bob, 1);
        vm.prank(bob);
        vm.expectRevert(BaskVault.InsufficientBalance.selector);
        vault.transfer(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transfer(address(0), 1);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.prank(bob);
        vault.transferFrom(alice, bob, 1);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    function testFuzzConservation(uint96 rawAmount, uint96 rawShares) public {
        uint256 amount = bound(uint256(rawAmount), 1e16, 5000e18);
        uint256 shares = _deposit(0, amount, alice);
        uint256 burn = bound(uint256(rawShares), 0, shares);
        uint256 supply = vault.totalSupply();
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(burn, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], amount * burn / supply);
        assertEq(
            stock[0].balanceOf(address(vault)), vault.managed(address(stock[0])) + vault.totalOwed(address(stock[0]))
        );
        assertEq(vault.totalSupply(), supply - burn);
        assertEq(vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(address(0xdEaD)));
    }

    function testLossDelayPartialRecoveryAndNoAutomaticWriteDown() public {
        _deposit(0, 10e18, alice);
        stock[0].confiscate(address(vault), 4e18);
        _status(_one(address(stock[1])), BaskVault.Reason.Short, address(stock[0]));
        vault.flagDeficit(address(stock[0]));
        (uint256 amount, uint256 since) = vault.deficits(address(stock[0]));
        assertEq(amount, 4e18);
        vm.warp(since + 1 days);
        vault.flagDeficit(address(stock[0]));
        (, uint256 sameSince) = vault.deficits(address(stock[0]));
        assertEq(sameSince, since);
        vm.expectRevert(BaskVault.Timelock.selector);
        vault.recognizeLoss(address(stock[0]));
        stock[0].mint(address(vault), 1e18);
        vm.warp(since + 7 days);
        vault.recognizeLoss(address(stock[0]));
        assertEq(vault.managed(address(stock[0])), 7e18);
        (amount, since) = vault.deficits(address(stock[0]));
        assertEq(amount + since, 0);
    }

    function testLargerDeficitRestartsAndDepositsClearRecords() public {
        _alwaysOpen();
        _deposit(0, 10e18, alice);
        stock[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stock[0]));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        stock[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stock[0]));
        (uint256 loss, uint256 since) = vault.deficits(address(stock[0]));
        assertEq(loss, 2e18);
        assertEq(since, vm.getBlockTimestamp());
        stock[0].mint(address(vault), 2e18);
        _refresh();
        _deposit(1, 1e18, bob);
        (loss, since) = vault.deficits(address(stock[0]));
        assertEq(loss + since, 0);
        stock[0].confiscate(address(vault), 1);
        vault.flagDeficit(address(stock[0]));
        stock[0].mint(address(vault), 1);
        vault.flagDeficit(address(stock[0]));
        (loss, since) = vault.deficits(address(stock[0]));
        assertEq(loss + since, 0);
    }

    function testResyncOnlyCountsSurplusAndDoesNotRecognizeLoss() public {
        _deposit(0, 10e18, alice);
        stock[0].mint(address(vault), 5e18);
        _execute(_propose(_action(BaskVault.Kind.Resync, address(stock[0]))));
        assertEq(vault.managed(address(stock[0])), 15e18);
        stock[0].confiscate(address(vault), 4e18);
        _execute(_propose(_action(BaskVault.Kind.Resync, address(stock[0]))));
        assertEq(vault.managed(address(stock[0])), 15e18);
    }

    function testDepositAfterPriceChangeRoundsGrossDown() public {
        _deposit(0, 10e18, alice);
        feed[0].set(300e8, vm.getBlockTimestamp());
        assertEq(_deposit(1, 1e18, bob), uint256(100e18) * 1000e18 / 3000e18);
    }

    function testMultiplePullsAreAtomic() public {
        address[] memory ts = new address[](2);
        ts[0] = address(stock[0]);
        ts[1] = address(stock[1]);
        uint256[] memory amts = new uint256[](2);
        amts[0] = 1e18;
        amts[1] = 1e18;
        stock[1].setTaxPull(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.PaymentFailed.selector, ts[1]));
        vault.deposit(ts, amts, alice, 0, vm.getBlockTimestamp());
        assertEq(stock[0].balanceOf(address(vault)), 0);
        assertEq(vault.managed(ts[0]), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function testZeroNAVCannotMintAgainstExistingShares() public {
        _alwaysOpen();
        _deposit(0, 1e18, alice);
        stock[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stock[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(stock[0]));
        _refresh();
        vm.expectRevert(BaskVault.ZeroNAV.selector);
        _deposit(1, 1e18, bob);
    }
}
