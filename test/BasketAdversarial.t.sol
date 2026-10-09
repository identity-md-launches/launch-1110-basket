// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {BaskVault} from "src/BaskVault.sol";
import {MockToken, MockFeed, MockPool} from "./mocks/Mocks.sol";

contract BasketAdversarialTest is VaultTestBase {
    function testEveryPrivilegedEntryRejectsAnUnrelatedCaller() public {
        BaskVault.Action memory action = _action(BaskVault.Kind.Resync, address(stock[0]));
        uint256 id = _propose(action);
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(vault.propose, (action));
        calls[1] = abi.encodeCall(vault.execute, (id));
        calls[2] = abi.encodeCall(vault.cancel, (id));
        calls[3] = abi.encodeCall(vault.close, (address(stock[0])));
        calls[4] = abi.encodeCall(vault.pauseDeposits, ());
        calls[5] = abi.encodeCall(vault.unpauseDeposits, ());
        calls[6] = abi.encodeCall(vault.lowerNAVCap, (0));
        calls[7] = abi.encodeCall(vault.transferOwnership, (bob));
        calls[8] = abi.encodeCall(vault.finalizeGenesis, ());
        calls[9] = abi.encodeCall(vault.listGenesis, (address(stock[0]), address(feed[0]), address(0), address(0), 0));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory reason) = address(vault).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(BaskVault.Unauthorized.selector));
        }
        assertEq(vault.owner(), OWNER);
        assertFalse(vault.depositsPaused());
        assertTrue(vault.asset(address(stock[0])).open);
        (, bool pending) = vault.proposal(id);
        assertTrue(pending);
    }

    function testGuardianCannotGainOwnerOnlyPowers() public {
        BaskVault.Action memory action = _action(BaskVault.Kind.FeeRecipient, address(0));
        action.target = bob;
        vm.startPrank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.lowerNAVCap(0);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.transferOwnership(bob);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.propose(action);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.acceptOwnership();
        vm.stopPrank();
    }

    function testProposalLastExecutableSecondAndFirstExpiredSecond() public {
        BaskVault.Action memory a = _action(BaskVault.Kind.FeeRecipient, address(0));
        a.target = recipient;
        uint256 first = _propose(a);
        a.target = bob;
        uint256 second = _propose(a);
        uint256 created = vm.getBlockTimestamp();
        vm.warp(created + 9 days - 1);
        vm.prank(OWNER);
        vault.execute(first);
        assertEq(vault.feeRecipient(), recipient);
        vm.warp(created + 9 days);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.execute(second);
        assertEq(vault.feeRecipient(), recipient);
    }

    function testFirstDepositAtLockBoundaryAndOneUnitAbove() public {
        vm.expectRevert(BaskVault.Slippage.selector);
        _deposit(0, 1e13, alice); // $100/token gives exactly 1e15 share wei.
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.managed(address(stock[0])), 0);
        assertEq(_deposit(0, 1e13 + 1, alice), 100);
        assertEq(vault.totalSupply(), 1e15 + 100);
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
    }

    function testZeroAndEmptyOperationsCannotCreateSharesOrDebt() public {
        vm.prank(alice);
        uint256[] memory emptyLegs = vault.redeem(0, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(emptyLegs, new uint256[](3));
        vm.prank(alice);
        vault.claim(new address[](0), bob);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.deposit(new address[](0), new uint256[](0), alice, 0, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.claim(new address[](0), address(0));
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalOwed(address(stock[0])), 0);
    }

    function testClaimBatchFailureRevertsEarlierPaymentsAndDuplicateClaimsPayOnce() public {
        _alwaysOpen();
        _setting(BaskVault.Setting.DirectLimit, 0, 0);
        _deposit(0, 10e18, alice);
        _deposit(1, 10e18, alice);
        vm.prank(alice);
        vault.redeem(1000e18, bob, new uint256[](0), vm.getBlockTimestamp());
        address[] memory ts = new address[](2);
        ts[0] = address(stock[0]);
        ts[1] = address(stock[1]);
        uint256 before0 = stock[0].rawBalance(alice);
        uint256 before1 = stock[1].rawBalance(alice);
        stock[1].setTransferMode(3); // Moves balances, then returns false.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.PaymentFailed.selector, ts[1]));
        vault.claim(ts, alice);
        assertEq(stock[0].rawBalance(alice), before0);
        assertEq(stock[1].rawBalance(alice), before1);
        assertEq(vault.owed(bob, ts[0]), 5e18);
        assertEq(vault.owed(bob, ts[1]), 5e18);
        assertEq(vault.totalOwed(ts[0]), 5e18);
        ts[1] = ts[0];
        vm.prank(bob);
        vault.claim(ts, alice);
        assertEq(stock[0].rawBalance(alice) - before0, 5e18);
        assertEq(vault.totalOwed(ts[0]), 0);
        vm.prank(alice); // A different caller cannot claim Bob's remaining debt.
        vault.claim(_one(address(stock[1])), alice);
        assertEq(vault.owed(bob, address(stock[1])), 5e18);
    }

    function testLateRedemptionSlippageRestoresEarlierPaymentFeeAndBurn() public {
        _setFee();
        _deposit(0, 10e18, alice);
        _deposit(1, 10e18, alice);
        uint256 supply = vault.totalSupply();
        uint256 feeShares = vault.balanceOf(recipient);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 beforeBalance = stock[0].rawBalance(bob);
        uint256[] memory minima = new uint256[](3);
        minima[1] = 6e18;
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(1000e18, bob, minima, vm.getBlockTimestamp());
        assertEq(stock[0].rawBalance(bob), beforeBalance);
        assertEq(vault.managed(address(stock[0])), 10e18);
        assertEq(vault.managed(address(stock[1])), 10e18);
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(recipient), feeShares);
        assertEq(vault.balanceOf(alice), aliceShares);
    }

    function testFeeRecipientRedeemsItsOwnSharesWithoutSupplyOrValueCreation() public {
        _setFee();
        _deposit(0, 100e18, alice);
        uint256 shares = vault.balanceOf(recipient);
        uint256 supply = vault.totalSupply();
        uint256 beforeBalance = stock[0].rawBalance(recipient);
        vm.prank(recipient);
        uint256[] memory legs = vault.redeem(shares, recipient, new uint256[](0), vm.getBlockTimestamp());
        uint256 remaining = vault.balanceOf(recipient);
        assertEq(remaining, 25e16); // 0.5% of the 50 BASK deposit fee.
        assertEq(vault.totalSupply(), supply - shares + remaining);
        assertEq(stock[0].rawBalance(recipient) - beforeBalance, legs[0]);
        assertEq(stock[0].rawBalance(address(vault)) + legs[0], 100e18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRepeatedCyclesCannotExtractRoundingDust(uint96 raw, uint8 count, bool withFee) public {
        _alwaysOpen();
        if (withFee) _setFee();
        _deposit(0, 31e18 + 7, bob);
        _deposit(1, 17e18 + 3, bob);
        uint256 amount = bound(raw, 1, 100e18);
        uint256 rounds = bound(count, 2, 16);
        uint256 beforeValue = stock[0].rawBalance(alice) + stock[1].rawBalance(alice);
        for (uint256 i; i < rounds; ++i) {
            uint256 shares = _deposit(i % 2, amount, alice);
            vm.prank(alice);
            vault.redeem(shares, alice, new uint256[](0), vm.getBlockTimestamp());
            assertEq(vault.balanceOf(alice), 0);
            assertLe(stock[0].rawBalance(alice) + stock[1].rawBalance(alice), beforeValue);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzUnaccountedDonationCannotInflateDepositPrice(uint128 rawDonation) public {
        _deposit(0, 1e13 + 1, alice);
        uint256 donation = uint256(rawDonation);
        (uint256 beforeShares,, uint256 beforeValue, uint256 beforeNav) =
            vault.previewDeposit(_one(address(stock[0])), _amount(1e18));
        stock[0].mint(address(vault), donation);
        (uint256 afterShares,, uint256 afterValue, uint256 afterNav) =
            vault.previewDeposit(_one(address(stock[0])), _amount(1e18));
        assertEq(afterShares, beforeShares);
        assertEq(afterValue, beforeValue);
        assertEq(afterNav, beforeNav);
        assertEq(_deposit(0, 1e18, bob), beforeShares);
        assertEq(vault.managed(address(stock[0])), 1e18 + 1e13 + 1);
    }

    function testEveryBoundedSettingRejectsValuesOutsideItsRange() public {
        uint256[13] memory low =
            [uint256(2), 1 hours, 1 hours, 0, 1, 0, 300, 50, 20_000, 20_000, 20_000, 20_000, 20_000];
        uint256[13] memory high =
            [uint256(100), 30 days, 30 days, 10, 48, 2, 86400, 2000, 500_000, 500_000, 500_000, 500_000, 500_000];
        for (uint256 i; i < 13; ++i) {
            // Hours is the sole two-value setting and is checked separately.
            uint256 ordinal = i < 5 ? i : i + 1;
            BaskVault.Action memory a = _action(BaskVault.Kind.Setting, address(0));
            a.setting = BaskVault.Setting(ordinal);
            a.value = high[i] + 1;
            vm.expectRevert(BaskVault.InvalidSetting.selector);
            _propose(a);
            a.value = type(uint256).max;
            vm.expectRevert(BaskVault.InvalidSetting.selector);
            _propose(a);
            if (low[i] != 0) {
                a.value = low[i] - 1;
                vm.expectRevert(BaskVault.InvalidSetting.selector);
                _propose(a);
            }
        }
        BaskVault.Action memory hoursAction = _action(BaskVault.Kind.Setting, address(0));
        hoursAction.setting = BaskVault.Setting.Hours;
        hoursAction.value = 1;
        hoursAction.value2 = 604801;
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _propose(hoursAction);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzAnyLegalSettingPreservesRedemptionAndClaim(uint8 settingSeed, uint256 raw) public {
        _deposit(0, 10e18, alice);
        // This permits the entire documented gas range for any subsequent setting.
        _setting(BaskVault.Setting.DirectLimit, 0, 0);
        _setting(BaskVault.Setting.MaxAssets, 3, 0);
        BaskVault.Setting s = BaskVault.Setting(settingSeed % 16);
        uint256 value;
        uint256 value2;
        if (s == BaskVault.Setting.Band) {
            value = bound(raw, 2, 100);
        } else if (s == BaskVault.Setting.MaxAge || s == BaskVault.Setting.NoPoolAge) {
            value = bound(raw, 1 hours, 30 days);
        } else if (s == BaskVault.Setting.FreshCount) {
            value = bound(raw, 0, 10);
        } else if (s == BaskVault.Setting.FreshHours) {
            value = bound(raw, 1, 48);
        } else if (s == BaskVault.Setting.Hours) {
            value = bound(raw, 0, 604799);
            value2 = value + 1;
        } else if (s == BaskVault.Setting.Dst) {
            value = bound(raw, 0, 2);
        } else if (s == BaskVault.Setting.PoolWindow) {
            value = bound(raw, 300, 86400);
        } else if (s == BaskVault.Setting.PoolDeviation) {
            value = bound(raw, 50, 2000);
        } else if (s == BaskVault.Setting.MaxAssets) {
            value = bound(raw, 3, uint256(28_000_000) / 110_000);
        } else if (s == BaskVault.Setting.DirectLimit) {
            value = bound(raw, 0, uint256(28_000_000) / 370_000);
        } else {
            value = bound(raw, 20_000, 500_000);
        }
        _setting(s, value, value2);
        vm.prank(GUARDIAN);
        vault.close(address(stock[0]));
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        feed[0].setMode(2);
        stock[0].setPaused(true);
        stock[0].setBalanceMode(2);
        stock[0].setTransferMode(2);
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(500e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], 5e18);
        assertEq(vault.owed(bob, address(stock[0])), 5e18);
        assertEq(vault.totalSupply(), 500e18);
        stock[0].setBalanceMode(6); // Needs more gas than the usual balanceGas.
        stock[0].setTransferMode(8); // Needs more gas than the usual payGas.
        uint256 beforeBalance = stock[0].rawBalance(bob);
        vm.prank(bob);
        vault.claim(_one(address(stock[0])), bob);
        assertEq(stock[0].rawBalance(bob) - beforeBalance, 5e18);
        assertEq(vault.totalOwed(address(stock[0])), 0);
    }

    function testInvalidPoolPairAndNoPoolResidualConfigAreRejected() public {
        MockPool unrelated = new MockPool(address(stock[1]), address(stock[2]));
        MockPool duplicate = new MockPool(address(stock[0]), address(stock[0]));
        BaskVault.Action memory a = _action(BaskVault.Kind.Pool, address(stock[0]));
        a.quoteFeed = address(feed[1]);
        a.pool = address(unrelated);
        vm.expectRevert(BaskVault.InvalidPool.selector);
        _propose(a);
        a.pool = address(duplicate);
        vm.expectRevert(BaskVault.InvalidPool.selector);
        _propose(a);
        a.pool = address(0);
        vm.expectRevert(BaskVault.InvalidPool.selector);
        _propose(a);
        a.quoteFeed = address(0);
        a.value = 1;
        vm.expectRevert(BaskVault.InvalidPool.selector);
        _propose(a);
    }

    function testListingExecutionRechecksDecimalsAndFeedUniqueness() public {
        MockToken first = new MockToken(18);
        MockToken second = new MockToken(18);
        MockFeed f = new MockFeed(8, 100e8);
        BaskVault.Action memory a = _action(BaskVault.Kind.List, address(first));
        a.target = address(f);
        uint256 firstId = _propose(a);
        a.token = address(second);
        uint256 secondId = _propose(a);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        first.setDecimals(19);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidFeed.selector);
        vault.execute(firstId);
        first.setDecimals(18);
        f.setDecimals(19);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidFeed.selector);
        vault.execute(firstId);
        f.setDecimals(8);
        vm.prank(OWNER);
        vault.execute(firstId);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidFeed.selector);
        vault.execute(secondId);
        assertEq(vault.assetCount(), 4);
        assertEq(vault.feedAsset(address(f)), address(first));
    }
}
