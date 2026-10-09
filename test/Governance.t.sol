// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

contract GovernanceTest is VaultTestBase {
    function testGenesisNeedsThreeAndOnlyOnce() public {
        BaskVault v = new BaskVault(OWNER, GUARDIAN);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        v.finalizeGenesis();
        for (uint256 i; i < 3; ++i) {
            vm.prank(OWNER);
            v.listGenesis(address(stock[i]), address(feed[i]), address(0), address(0), 0);
        }
        vm.prank(OWNER);
        v.finalizeGenesis();
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        v.finalizeGenesis();
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        v.listGenesis(address(stock[0]), address(feed[0]), address(0), address(0), 0);
    }

    function testOnlyOwnerProposesExecutesAndTwoDayWindow() public {
        BaskVault.Action memory a = _action(BaskVault.Kind.FeeRecipient, address(0));
        a.target = recipient;
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.propose(a);
        uint256 id = _propose(a);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.Timelock.selector);
        vault.execute(id);
        vm.warp(vm.getBlockTimestamp() + 2 days - 1);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.Timelock.selector);
        vault.execute(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.execute(id);
        vm.prank(OWNER);
        vault.execute(id);
        assertEq(vault.feeRecipient(), recipient);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.execute(id);
    }

    function testExpiryAndCancellation() public {
        BaskVault.Action memory a = _action(BaskVault.Kind.Recentre, address(stock[0]));
        uint256 first = _propose(a);
        uint256 second = _propose(a);
        assertEq(vault.pendingProposals(0, 100).length, 2);
        vm.prank(GUARDIAN);
        vault.cancel(first);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.execute(first);
        vm.warp(vm.getBlockTimestamp() + 9 days);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.execute(second);
        assertEq(vault.pendingProposals(1, 100).length, 0);
    }

    function testGuardianCannotCancelReplacementAndRolesRemainDistinct() public {
        BaskVault.Action memory a = _action(BaskVault.Kind.Guardian, address(0));
        a.target = bob;
        uint256 id = _propose(a);
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.cancel(id);
        vm.prank(OWNER);
        vault.transferOwnership(bob);
        vm.prank(bob);
        vault.acceptOwnership();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(bob);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.execute(id);
        vm.prank(bob);
        vault.cancel(id);
        assertEq(vault.guardian(), GUARDIAN);
    }

    function testTwoStepOwnershipAndGuardianCannotUnpause() public {
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(GUARDIAN);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(address(0));
        vm.prank(OWNER);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), OWNER);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.acceptOwnership();
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.unpauseDeposits();
        vm.prank(bob);
        vault.unpauseDeposits();
    }

    function testLaterCloseVoidsReopenEvenIfAlreadyClosed() public {
        address token = address(stock[0]);
        vm.prank(OWNER);
        vault.close(token);
        uint256 id = _propose(_action(BaskVault.Kind.Reopen, token));
        vm.prank(GUARDIAN);
        vault.close(token);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.execute(id);
        _execute(_propose(_action(BaskVault.Kind.Reopen, token)));
        assertTrue(vault.asset(token).open);
    }

    function testRetirementRequiresClosedAtProposalAndExecution() public {
        address token = address(stock[0]);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        _propose(_action(BaskVault.Kind.Retire, token));
        vm.prank(OWNER);
        vault.close(token);
        uint256 retire = _propose(_action(BaskVault.Kind.Retire, token));
        uint256 reopen = _propose(_action(BaskVault.Kind.Reopen, token));
        _execute(reopen);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.execute(retire);
    }

    function testRetireVoidsProposalsSkipsAllDepositChecksAndSharesTokens() public {
        _alwaysOpen();
        _deposit(0, 10e18, alice);
        _deposit(1, 10e18, alice);
        address token = address(stock[0]);
        vm.prank(OWNER);
        vault.close(token);
        uint256 resync = _propose(_action(BaskVault.Kind.Resync, token));
        uint256 reopen = _propose(_action(BaskVault.Kind.Reopen, token));
        _execute(_propose(_action(BaskVault.Kind.Retire, token)));
        (, bool pending) = vault.proposal(resync);
        assertFalse(pending);
        (, pending) = vault.proposal(reopen);
        assertFalse(pending);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        _propose(_action(BaskVault.Kind.Reopen, token));
        feed[0].setMode(2);
        stock[0].setBalanceMode(2);
        stock[0].setPaused(true);
        assertEq(_deposit(1, 10e18, bob), 2000e18);
        // Retirement removes value, but redemption still includes the retired tokens.
        vm.prank(bob);
        uint256[] memory legs = vault.redeem(2000e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], 5e18);
        assertEq(vault.owed(bob, token), 5e18);
        stock[0].setBalanceMode(0);
        stock[0].mint(address(vault), 1e18);
        _execute(_propose(_action(BaskVault.Kind.Resync, token)));
        assertEq(vault.managed(token), 6e18);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        vault.removeRetired(token);
    }

    function testRemoveRelistAndReuseRetiredFeed() public {
        address token = address(stock[0]);
        vm.prank(OWNER);
        vault.close(token);
        _execute(_propose(_action(BaskVault.Kind.Retire, token)));
        uint256 stale = _propose(_action(BaskVault.Kind.Resync, token));
        vault.removeRetired(token);
        assertEq(vault.assetCount(), 2);
        BaskVault.Action memory a = _action(BaskVault.Kind.List, token);
        a.target = address(feed[0]);
        _execute(_propose(a));
        assertTrue(vault.asset(token).open);
        assertFalse(vault.asset(token).retired);
        (, bool pending) = vault.proposal(stale);
        assertFalse(pending);
        assertEq(vault.assetCount(), 3);
    }

    function testListingChecksAtProposalAndExecution() public {
        MockToken t = new MockToken(18);
        MockFeed f = new MockFeed(8, 100e8);
        BaskVault.Action memory a = _action(BaskVault.Kind.List, address(t));
        a.target = address(feed[0]);
        vm.expectRevert(BaskVault.InvalidFeed.selector);
        _propose(a);
        a.target = address(f);
        t.setDecimals(19);
        vm.expectRevert(BaskVault.InvalidFeed.selector);
        _propose(a);
        t.setDecimals(18);
        uint256 id = _propose(a);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        f.set(0, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidFeed.selector);
        vault.execute(id);
        f.set(120e8, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vault.execute(id);
        assertEq(vault.asset(address(t)).centre, 120e8);
        vm.expectRevert(BaskVault.InvalidAsset.selector);
        _propose(a);
    }

    function testFeedAndRecentreUseExecutionAnswer() public {
        MockFeed f = new MockFeed(6, 50e6);
        BaskVault.Action memory a = _action(BaskVault.Kind.Feed, address(stock[0]));
        a.target = address(f);
        uint256 id = _propose(a);
        f.set(55e6, vm.getBlockTimestamp() + 2 days);
        _execute(id);
        assertEq(vault.asset(address(stock[0])).centre, 55e6);
        assertEq(vault.asset(address(stock[0])).feedDecimals, 6);
        assertEq(vault.feedAsset(address(feed[0])), address(0));
        id = _propose(_action(BaskVault.Kind.Recentre, address(stock[0])));
        f.set(80e6, vm.getBlockTimestamp() + 2 days);
        _execute(id);
        assertEq(vault.asset(address(stock[0])).centre, 80e6);
    }

    function testCapLoweringInvalidatesAllPendingRaises() public {
        BaskVault.Action memory a = _action(BaskVault.Kind.RaiseCap, address(0));
        a.value = 2_000_000e18;
        uint256 id = _propose(a);
        vm.prank(OWNER);
        vault.lowerNAVCap(900_000e18);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidProposal.selector);
        vault.execute(id);
        _execute(_propose(a));
        assertEq(vault.NAV_CAP(), a.value);
        a.value = 10_000_000_000e18 + 1;
        vm.expectRevert(BaskVault.InvalidInput.selector);
        _propose(a);
        a.kind = BaskVault.Kind.FeeRecipient;
        a.target = address(vault);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        _propose(a);
        a.target = address(0);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        _propose(a);
    }

    function testSettingBoundsAndBothGasConstraintsRechecked() public {
        BaskVault.Action memory a = _action(BaskVault.Kind.Setting, address(0));
        a.setting = BaskVault.Setting.Band;
        a.value = 1;
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _propose(a);
        a.setting = BaskVault.Setting.MaxAssets;
        a.value = 2;
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _propose(a);
        a.value = 255;
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _propose(a);
        a.setting = BaskVault.Setting.DirectLimit;
        a.value = 76;
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _propose(a);
        a.setting = BaskVault.Setting.Hours;
        a.value = 10;
        a.value2 = 9;
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _propose(a);
        a.setting = BaskVault.Setting.BalanceGas;
        a.value = 52_000;
        a.value2 = 0;
        uint256 id = _propose(a);
        _setting(BaskVault.Setting.MaxAssets, 254, 0);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.execute(id);
        assertEq(vault.settings().balanceGas, 50_000);
    }

    function testRemovingEmptyAssetPreservesMovedManagedAssetAndMinimumOrder() public {
        _deposit(2, 10e18, alice);
        vm.prank(OWNER);
        vault.close(address(stock[0]));
        _execute(_propose(_action(BaskVault.Kind.Retire, address(stock[0]))));
        vault.removeRetired(address(stock[0]));
        assertEq(vault.assetTokens()[0], address(stock[2]));
        vm.prank(alice);
        uint256[] memory amounts = vault.redeem(500e18, bob, _amount(5e18), vm.getBlockTimestamp());
        assertEq(amounts.length, 2);
        assertEq(amounts[0], 5e18);
        assertEq(amounts[1], 0);
    }

    function testLossClearsManagedBitAndResyncRestoresIt() public {
        _deposit(0, 10e18, alice);
        stock[0].confiscate(address(vault), 10e18);
        vault.flagDeficit(address(stock[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(stock[0]));
        vm.prank(alice);
        uint256[] memory amounts = vault.redeem(100e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(amounts[0], 0);
        stock[0].mint(address(vault), 9e18);
        _execute(_propose(_action(BaskVault.Kind.Resync, address(stock[0]))));
        vm.prank(alice);
        amounts = vault.redeem(100e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(amounts[0], 1e18);
    }
}
