// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

contract RedemptionGasTest is VaultTestBase {
    MockToken[] private many;
    MockFeed[] private prices;

    function setUp() public override {
        vm.warp(1_789_992_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vault = new BaskVault(OWNER, GUARDIAN);
    }

    function _configure(BaskVault.Setting s, uint256 v) private {
        BaskVault.Action memory a = _action(BaskVault.Kind.Setting, address(0));
        a.setting = s;
        a.value = v;
        uint256 id = _propose(a);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vault.execute(id);
    }

    function _populate(uint256 count, uint256 active) private {
        _configure(BaskVault.Setting.Hours, 0);
        address[] memory ts = new address[](active);
        uint256[] memory amounts = new uint256[](active);
        for (uint256 i; i < count; ++i) {
            MockToken t = new MockToken(18);
            MockFeed f = new MockFeed(8, 1e8);
            many.push(t);
            prices.push(f);
            vm.prank(OWNER);
            vault.listGenesis(address(t), address(f), address(0), address(0), 0);
            if (i < active) {
                t.mint(alice, 1e18);
                vm.prank(alice);
                t.approve(address(vault), 1e18);
                ts[i] = address(t);
                amounts[i] = 1e18;
            }
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vm.prank(alice);
        vault.deposit(ts, amounts, alice, 0, vm.getBlockTimestamp());
    }

    function _attack(uint256 active, uint256 balanceMode, uint256 transferMode) private {
        for (uint256 i; i < many.length; ++i) {
            many[i].setBalanceMode(balanceMode);
            many[i].setTransferMode(transferMode);
            many[i].setPaused(true);
            prices[i].setMode(2);
            vm.cool(address(many[i]));
        }
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        uint256 shares = vault.balanceOf(alice);
        (uint256[] memory minima,,) = vault.previewRedeem(shares);
        for (uint256 i; i < many.length; ++i) {
            vm.cool(address(many[i]));
        }
        vm.cool(address(vault));
        uint256 before = gasleft();
        vm.prank(alice);
        uint256[] memory legs = vault.redeem{gas: 27_950_000}(shares, bob, minima, vm.getBlockTimestamp());
        uint256 used = before - gasleft();
        emit log_named_uint("cold redemption gas", used);
        // Include intrinsic transaction/calldata gas, not just execution gas.
        bytes memory data = abi.encodeCall(vault.redeem, (shares, bob, minima, vm.getBlockTimestamp()));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        emit log_named_uint("including transaction calldata", used + intrinsic);
        assertLt(used + intrinsic, 28_000_000);
        assertEq(legs.length, many.length);
        for (uint256 i; i < active; ++i) {
            assertGt(legs[i], 0);
            assertEq(vault.owed(bob, address(many[i])), legs[i]);
        }
    }

    function testGas250UnreadableUpgradedTokens() public {
        _populate(250, 250);
        _attack(250, 2, 2);
    }

    function testGas250BlockedTokensWithExpensiveReadableBalances() public {
        _populate(250, 250);
        _attack(250, 5, 1);
    }

    function testGas50DirectPaymentsConsumeAllPayGasAmong250Assets() public {
        _populate(250, 50);
        _attack(50, 5, 2);
    }

    function testGasMaximumAssetCount350AtMinimumBalanceGas() public {
        _configure(BaskVault.Setting.BalanceGas, 20_000);
        _configure(BaskVault.Setting.MaxAssets, 350);
        _populate(350, 350);
        _attack(350, 2, 2);
    }

    function testGasMaximumBalanceGasAtMaximumAllowedAssetCount50() public {
        _configure(BaskVault.Setting.MaxAssets, 50);
        _configure(BaskVault.Setting.DirectLimit, 0);
        _configure(BaskVault.Setting.BalanceGas, 500_000);
        _populate(50, 50);
        BaskVault.Action memory a = _action(BaskVault.Kind.FeeRecipient, address(0));
        a.target = makeAddr("gas-fee-recipient");
        uint256 id = _propose(a);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vault.execute(id);
        _attack(50, 2, 2);
    }

    function testGasMaximumDirectCountAtMinimumCallBudgets() public {
        _configure(BaskVault.Setting.BalanceGas, 20_000);
        _configure(BaskVault.Setting.PayGas, 20_000);
        _configure(BaskVault.Setting.MaxAssets, 350);
        _configure(BaskVault.Setting.DirectLimit, 254);
        _populate(350, 254);
        _attack(254, 5, 2);
    }

    function testGasMaximumPayGasWithManyEmptyAssets() public {
        _configure(BaskVault.Setting.BalanceGas, 20_000);
        _configure(BaskVault.Setting.MaxAssets, 350);
        _configure(BaskVault.Setting.DirectLimit, 47);
        _configure(BaskVault.Setting.PayGas, 500_000);
        _populate(350, 47);
        _attack(47, 5, 2);
    }

    function testGasMaximumBalancesUseFullPrecisionMath() public {
        _configure(BaskVault.Setting.MaxAssets, 50);
        _configure(BaskVault.Setting.DirectLimit, 0);
        _configure(BaskVault.Setting.BalanceGas, 500_000);
        _populate(50, 50);
        uint256[] memory ids = new uint256[](50);
        for (uint256 i; i < 50; ++i) {
            many[i].mint(address(vault), type(uint256).max - 1e18);
            ids[i] = _propose(_action(BaskVault.Kind.Resync, address(many[i])));
        }
        BaskVault.Action memory a = _action(BaskVault.Kind.FeeRecipient, address(0));
        a.target = makeAddr("large-balance-fee-recipient");
        uint256 feeId = _propose(a);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        for (uint256 i; i < 50; ++i) {
            vm.prank(OWNER);
            vault.execute(ids[i]);
        }
        vm.prank(OWNER);
        vault.execute(feeId);
        _attack(50, 2, 2);
    }
}
