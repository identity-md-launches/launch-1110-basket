// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "src/BaskVault.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

/// @dev All Stock Tokens in this campaign have 18 decimals and a fixed $100 price.
/// Losses are explicit mock confiscations; hostile reads never change physical balances.
contract BasketHandler is Test {
    BaskVault public immutable vault;
    address private constant OWNER = 0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3;
    address private constant GUARDIAN = 0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68;
    MockToken[3] public stocks;
    MockFeed[3] public feeds;
    address[4] public actors;

    uint256[3] public deposited;
    uint256[3] public donated;
    uint256[3] public destroyed;
    uint256[3] public paid;
    uint256[3] public synchronized;
    uint256[3] public redeemed;
    uint256[3] public recognized;
    uint256 public successfulDeposits;
    uint256 public successfulRedeems;
    uint256 public successfulClaims;

    constructor(BaskVault v, MockToken[3] memory ts, MockFeed[3] memory fs, address[4] memory users) {
        vault = v;
        stocks = ts;
        feeds = fs;
        actors = users;
    }

    function _tokens(uint256 i) private view returns (address[] memory ts) {
        ts = new address[](1);
        ts[0] = address(stocks[i]);
    }

    function deposit(uint256 actorSeed, uint256 receiverSeed, uint256 tokenSeed, uint256 raw) public {
        address who = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 i = tokenSeed % 3;
        uint256 amount = bound(raw, 1e14, 50e18);
        address shortToken;
        uint256 nav;
        // Repair external read failures, but preserve deficits, debt and protocol pauses.
        for (uint256 j; j < 3; ++j) {
            stocks[j].setBalanceMode(0);
            stocks[j].setPaused(false);
            feeds[j].setMode(0);
            feeds[j].set(100e8, vm.getBlockTimestamp());
            uint256 balance = stocks[j].rawBalance(address(vault));
            uint256 debt = vault.totalOwed(address(stocks[j]));
            uint256 m = vault.managed(address(stocks[j]));
            uint256 available = balance > debt ? balance - debt : 0;
            if (shortToken == address(0) && (available < m || (j == i && balance < debt))) {
                shortToken = address(stocks[j]);
            }
            nav += m * 100;
        }
        stocks[i].mint(who, amount);
        vm.prank(who);
        stocks[i].approve(address(vault), amount);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256 supply = vault.totalSupply();
        if (vault.depositsPaused()) {
            vm.expectRevert(
                abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, BaskVault.Reason.Paused, address(0))
            );
        } else if (shortToken != address(0)) {
            (BaskVault.Reason reason, address fault) = vault.depositStatus(_tokens(i));
            assertEq(uint256(reason), uint256(BaskVault.Reason.Short));
            assertEq(fault, shortToken);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, reason, fault));
        } else if (supply != 0 && nav == 0) {
            vm.expectRevert(BaskVault.ZeroNAV.selector);
        } else {
            uint256 receiverBefore = vault.balanceOf(receiver);
            uint256 walletBefore = stocks[i].rawBalance(who);
            vm.prank(who);
            uint256 shares = vault.deposit(_tokens(i), amounts, receiver, 0, vm.getBlockTimestamp());
            assertGt(shares, 0);
            assertEq(walletBefore - stocks[i].rawBalance(who), amount);
            // The receiver can also be the fee recipient, so it may receive more.
            assertGe(vault.balanceOf(receiver) - receiverBefore, shares);
            deposited[i] += amount;
            ++successfulDeposits;
            return;
        }
        vm.prank(who);
        vault.deposit(_tokens(i), amounts, receiver, 0, vm.getBlockTimestamp());
    }

    struct BeforeRedeem {
        uint256 supply;
        uint256 fee;
        uint256[3] physical;
        uint256[3] managed;
        uint256[3] debt;
        uint256[3] available;
    }

    function redeem(uint256 actorSeed, uint256 receiverSeed, uint256 raw, bool full) public {
        address who = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 owned = vault.balanceOf(who);
        uint256 shares = full ? owned : bound(raw, 0, owned);
        BeforeRedeem memory b;
        b.supply = vault.totalSupply();
        b.fee = (shares + 199) / 200;
        for (uint256 i; i < 3; ++i) {
            address t = address(stocks[i]);
            b.physical[i] = stocks[i].rawBalance(address(vault));
            b.managed[i] = vault.managed(t);
            b.debt[i] = vault.owed(receiver, t);
            uint256 totalDebt = vault.totalOwed(t);
            uint256 mode = stocks[i].balanceMode();
            b.available[i] = mode == 1 || mode == 2 || mode == 3
                ? b.managed[i]
                : (b.physical[i] > totalDebt ? b.physical[i] - totalDebt : 0);
        }
        vm.prank(who);
        uint256[] memory legs = vault.redeem(shares, receiver, new uint256[](0), vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), b.supply - (shares - b.fee));
        for (uint256 i; i < 3; ++i) {
            address t = address(stocks[i]);
            uint256 debit = b.physical[i] - stocks[i].rawBalance(address(vault));
            uint256 credit = vault.owed(receiver, t) - b.debt[i];
            assertEq(debit + credit, legs[i], "a leg must be paid or owed exactly once");
            assertEq(vault.managed(t) + legs[i], b.managed[i]);
            if (b.supply != 0) {
                uint256 numerator = min(b.managed[i], b.available[i]) * (shares - b.fee);
                assertLe(legs[i] * b.supply, numerator, "leg rounds up");
                assertLt(numerator - legs[i] * b.supply, b.supply, "leg loses more than dust");
            }
            paid[i] += debit;
            redeemed[i] += legs[i];
        }
        ++successfulRedeems;
    }

    function claim(uint256 actorSeed, uint256 receiverSeed, uint256 tokenSeed) public {
        address who = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 i = tokenSeed % 3;
        MockToken token = stocks[i];
        token.setBalanceMode(0);
        token.setTransferMode(0);
        uint256 beforeBalance = token.rawBalance(address(vault));
        uint256 receiverBefore = token.rawBalance(receiver);
        uint256 debt = vault.owed(who, address(token));
        uint256 expected = min(debt, beforeBalance);
        vm.prank(who);
        vault.claim(_tokens(i), receiver);
        assertEq(token.rawBalance(receiver) - receiverBefore, expected);
        assertEq(vault.owed(who, address(token)), debt - expected);
        assertEq(beforeBalance - token.rawBalance(address(vault)), expected);
        paid[i] += expected;
        ++successfulClaims;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 raw) public {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(raw, 0, vault.balanceOf(from));
        vm.prank(from);
        vault.transfer(to, amount);
    }

    function donate(uint256 tokenSeed, uint256 raw) public {
        uint256 i = tokenSeed % 3;
        uint256 amount = bound(raw, 0, 50e18);
        stocks[i].mint(address(vault), amount);
        donated[i] += amount;
    }

    function confiscate(uint256 tokenSeed, uint256 raw) public {
        uint256 i = tokenSeed % 3;
        uint256 amount = bound(raw, 0, stocks[i].rawBalance(address(vault)));
        stocks[i].confiscate(address(vault), amount);
        destroyed[i] += amount;
    }

    function resync(uint256 tokenSeed) public {
        uint256 i = tokenSeed % 3;
        address token = address(stocks[i]);
        stocks[i].setBalanceMode(0);
        uint256 accounted = vault.managed(token) + vault.totalOwed(token);
        uint256 balance = stocks[i].rawBalance(address(vault));
        uint256 extra = balance > accounted ? balance - accounted : 0;
        BaskVault.Action memory action;
        action.kind = BaskVault.Kind.Resync;
        action.token = token;
        _execute(action);
        synchronized[i] += extra;
    }

    function loss(uint256 tokenSeed, uint256 elapsed) public {
        uint256 i = tokenSeed % 3;
        address token = address(stocks[i]);
        stocks[i].setBalanceMode(0);
        vault.flagDeficit(token);
        (uint256 record, uint256 since) = vault.deficits(token);
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 8 days));
        if (record == 0 || vm.getBlockTimestamp() < since + 7 days) {
            vm.expectRevert(BaskVault.Timelock.selector);
            vault.recognizeLoss(token);
            return;
        }
        uint256 physical = stocks[i].rawBalance(address(vault));
        uint256 debt = vault.totalOwed(token);
        uint256 available = physical > debt ? physical - debt : 0;
        uint256 m = vault.managed(token);
        uint256 shortfall = m > available ? m - available : 0;
        vault.recognizeLoss(token);
        recognized[i] += min(record, shortfall);
    }

    function tokenFailure(uint256 tokenSeed, uint256 balanceMode, uint256 transferMode, bool paused) public {
        uint256 i = tokenSeed % 3;
        stocks[i].setBalanceMode(balanceMode % 5);
        stocks[i].setTransferMode(transferMode % 9);
        stocks[i].setPaused(paused);
        feeds[i].setMode(paused ? 2 : 0);
    }

    function governance(bool pause, bool queue) public {
        if (pause) {
            vm.prank(GUARDIAN);
            vault.pauseDeposits();
        } else {
            vm.prank(OWNER);
            vault.unpauseDeposits();
        }
        BaskVault.Action memory action;
        action.kind = BaskVault.Kind.Setting;
        action.setting = BaskVault.Setting.DirectLimit;
        action.value = queue ? 0 : 50;
        _execute(action);
    }

    function _execute(BaskVault.Action memory action) private {
        vm.prank(OWNER);
        uint256 id = vault.propose(action);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vault.execute(id);
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract BasketInvariantTest is VaultTestBase {
    BasketHandler internal handler;
    address[4] internal actors;

    function setUp() public override {
        super.setUp();
        _alwaysOpen();
        _setFee();
        actors = [alice, bob, makeAddr("carol"), recipient];
        handler = new BasketHandler(vault, stock, feed, actors);
        // Ensure every run starts with value in custody, live shares, and a real debt.
        for (uint256 i; i < 3; ++i) {
            handler.deposit(i, i, i, 10e18);
        }
        handler.tokenFailure(0, 0, 1, true);
        handler.redeem(0, 1, 100e18, false);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.transferShares.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.confiscate.selector;
        selectors[6] = handler.resync.selector;
        selectors[7] = handler.loss.selector;
        selectors[8] = handler.tokenFailure.selector;
        selectors[9] = handler.governance.selector;
        selectors[10] = handler.redeem.selector; // Give withdrawals extra weight.
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_custodyAndManagedMatchIndependentFlows() public view {
        for (uint256 i; i < 3; ++i) {
            assertEq(
                stock[i].rawBalance(address(vault)) + handler.paid(i) + handler.destroyed(i),
                handler.deposited(i) + handler.donated(i),
                "physical assets must match external inputs less payouts and confiscations"
            );
            assertEq(
                vault.managed(address(stock[i])) + handler.redeemed(i) + handler.recognized(i),
                handler.deposited(i) + handler.synchronized(i),
                "only deposits/resync/redeem/recognized losses change managed"
            );
        }
    }

    function invariant_shareAndDebtTotalsEqualTheirOwners() public view {
        uint256 sum = vault.balanceOf(address(0xdEaD));
        for (uint256 j; j < actors.length; ++j) {
            sum += vault.balanceOf(actors[j]);
        }
        assertEq(sum, vault.totalSupply());
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15, "first-deposit lock minted exactly once");
        for (uint256 i; i < 3; ++i) {
            uint256 debts;
            for (uint256 j; j < actors.length; ++j) {
                debts += vault.owed(actors[j], address(stock[i]));
            }
            assertEq(debts, vault.totalOwed(address(stock[i])));
        }
    }

    function invariant_everyActorCanRedeemDespiteCurrentFailures() public {
        // Restore the campaign state explicitly after exercising all exits. Do not
        // repair any token, feed, pause or setting before checking withdrawal liveness.
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < actors.length; ++i) {
            handler.redeem(i, i, 0, true);
        }
        invariant_custodyAndManagedMatchIndependentFlows();
        invariant_shareAndDebtTotalsEqualTheirOwners();
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function testHandlerExercisesCustodyDebtLossAndRecovery() public {
        handler.claim(1, 2, 0);
        handler.donate(1, 2e18);
        handler.resync(1);
        handler.confiscate(2, 1e18);
        handler.loss(2, 7 days);
        handler.governance(true, true);
        handler.redeem(2, 0, 0, true);
        handler.claim(0, 1, 2);
        assertGt(handler.successfulDeposits(), 0);
        assertGt(handler.successfulRedeems(), 1);
        assertGt(handler.successfulClaims(), 0);
        assertGt(handler.recognized(2), 0);
        invariant_custodyAndManagedMatchIndependentFlows();
        invariant_shareAndDebtTotalsEqualTheirOwners();
    }
}
