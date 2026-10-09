// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {BaskVault} from "src/BaskVault.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

contract BasketUpgradeBomb {
    fallback() external {
        assembly ("memory-safe") { invalid() }
    }
}

contract BasketAssetBoundaryTest is VaultTestBase {
    MockToken[] internal stocks;

    function setUp() public override {
        vm.warp(1_789_992_000);
        alice = makeAddr("boundary-alice");
        bob = makeAddr("boundary-bob");
        vault = new BaskVault(OWNER, GUARDIAN);
        // _setting in VaultTestBase refreshes its three feeds after each warp.
        for (uint256 i; i < 3; ++i) {
            feed[i] = new MockFeed(8, 1e8);
        }
        _alwaysOpen();
    }

    function _populate(uint256 count, uint256[] memory selected) private {
        address[] memory ts = new address[](selected.length);
        uint256[] memory amounts = new uint256[](selected.length);
        uint256 next;
        for (uint256 i; i < count; ++i) {
            MockToken t = new MockToken(18);
            MockFeed f = new MockFeed(8, 1e8);
            stocks.push(t);
            vm.prank(OWNER);
            vault.listGenesis(address(t), address(f), address(0), address(0), 0);
            if (next < selected.length && selected[next] == i) {
                ts[next] = address(t);
                amounts[next] = 1e18;
                ++next;
                t.mint(alice, 1e18);
                vm.prank(alice);
                t.approve(address(vault), 1e18);
            }
        }
        assertEq(next, selected.length);
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vm.prank(alice);
        vault.deposit(ts, amounts, alice, 0, vm.getBlockTimestamp());
    }

    function _retire(address token) private {
        vm.prank(OWNER);
        vault.close(token);
        _execute(_propose(_action(BaskVault.Kind.Retire, token)));
    }

    function testSparseAssetsAcrossBothBitmapWordsSurviveRemovalAndResync() public {
        _setting(BaskVault.Setting.BalanceGas, 20_000, 0);
        _setting(BaskVault.Setting.MaxAssets, 350, 0);
        _setting(BaskVault.Setting.DirectLimit, 5, 0);
        uint256[] memory selected = new uint256[](5);
        selected[0] = 0;
        selected[1] = 1;
        selected[2] = 255;
        selected[3] = 256;
        selected[4] = 349;
        _populate(350, selected);

        // Move a live asset from the second bitmap word into the first.
        _retire(address(stocks[2]));
        vm.prank(bob);
        vault.removeRetired(address(stocks[2]));
        assertEq(vault.assetTokens()[2], address(stocks[349]));

        // Clear a live bit by loss recognition, then remove the retired empty asset.
        stocks[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stocks[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(stocks[0]));
        _retire(address(stocks[0]));
        vault.removeRetired(address(stocks[0]));
        assertEq(vault.assetCount(), 348);

        // Resync must restore an empty bit in the second word.
        stocks[300].mint(address(vault), 1e18);
        _execute(_propose(_action(BaskVault.Kind.Resync, address(stocks[300]))));
        (uint256[] memory preview,, bool direct) = vault.previewRedeem(1e18);
        assertTrue(direct, "five live assets should permit direct payment");
        address[] memory order = vault.assetTokens();
        for (uint256 i; i < stocks.length; ++i) {
            vm.cool(address(stocks[i]));
        }
        vm.cool(address(vault));
        vm.prank(alice);
        uint256[] memory actual = vault.redeem{gas: 27_950_000}(1e18, bob, new uint256[](0), vm.getBlockTimestamp());
        assertEq(actual, preview);
        uint256 nonzero;
        for (uint256 i; i < order.length; ++i) {
            bool live = order[i] == address(stocks[1]) || order[i] == address(stocks[255])
                || order[i] == address(stocks[256]) || order[i] == address(stocks[349])
                || order[i] == address(stocks[300]);
            assertEq(actual[i], live ? 0.2e18 : 0, "redemption leg follows the moved token");
            assertEq(MockToken(order[i]).rawBalance(bob), actual[i]);
            assertEq(vault.totalOwed(order[i]), 0);
            if (live) ++nonzero;
        }
        assertEq(nonzero, 5);
    }

    function test250MixedTokenFailuresAndRetirementStayBelowGasCeiling() public {
        uint256[] memory selected = new uint256[](250);
        for (uint256 i; i < selected.length; ++i) {
            selected[i] = i;
        }
        _populate(250, selected);
        bytes memory brokenCode = address(new BasketUpgradeBomb()).code;
        _retire(address(stocks[249]));
        vm.prank(OWNER);
        vault.lowerNAVCap(0);
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        for (uint256 i; i < stocks.length; ++i) {
            if (i % 5 == 0) {
                vm.etch(address(stocks[i]), brokenCode);
            } else if (i % 5 == 1) {
                stocks[i].setBalanceMode(3); // ABI became malformed after upgrade.
            } else if (i % 5 == 2) {
                stocks[i].setBalanceMode(4); // Large returndata, only 32 bytes needed.
            } else if (i % 5 == 3) {
                stocks[i].setTransferMode(1);
                stocks[i].setPaused(true);
            } else {
                stocks[i].confiscate(address(vault), 0.5e18);
            }
            vm.cool(address(stocks[i]));
        }
        vm.cool(address(vault));
        uint256[] memory minima = new uint256[](0);
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(alice);
        uint256 start = gasleft();
        uint256[] memory legs = vault.redeem{gas: 27_950_000}(125e18, bob, minima, deadline);
        uint256 used = start - gasleft();
        bytes memory data = abi.encodeCall(vault.redeem, (125e18, bob, minima, deadline));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        emit log_named_uint("mixed asset redemption including intrinsic gas", used + intrinsic);
        assertLt(used + intrinsic, 28_000_000);
        for (uint256 i; i < stocks.length; ++i) {
            uint256 expected = i % 5 == 4 ? 0.25e18 : 0.5e18;
            assertEq(legs[i], expected);
            assertEq(vault.owed(bob, address(stocks[i])), expected);
            assertEq(vault.totalOwed(address(stocks[i])), expected);
            assertEq(vault.managed(address(stocks[i])), 1e18 - expected);
        }
    }
}
