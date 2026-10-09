// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {MockToken, MockFeed, MockPool} from "./mocks/Mocks.sol";
import {PoolOracle} from "../src/libraries/PoolOracle.sol";

contract OracleHarness {
    function consult(address pool, uint32 window) external view returns (bool, int24, uint128) {
        return PoolOracle.consult(pool, window, 150_000);
    }

    function quote(int24 tick, uint128 amount, bool baseIsToken0) external pure returns (uint256) {
        return PoolOracle.quote(tick, amount, baseIsToken0);
    }
}

contract OracleTest is VaultTestBase {
    function testInvalidFeedAnswersFutureStaleAndBoundedFailures() public {
        address token = address(stock[0]);
        for (uint256 mode = 1; mode <= 3; ++mode) {
            feed[0].setMode(mode);
            _status(_one(token), BaskVault.Reason.Feed, token);
        }
        feed[0].setMode(0);
        feed[0].set(0, vm.getBlockTimestamp());
        _status(_one(token), BaskVault.Reason.Feed, token);
        feed[0].set(-1, vm.getBlockTimestamp());
        _status(_one(token), BaskVault.Reason.Feed, token);
        feed[0].set(100e8, vm.getBlockTimestamp() + 1);
        _status(_one(token), BaskVault.Reason.Feed, token);
        feed[0].set(100e8, vm.getBlockTimestamp() - 80 hours - 1);
        _status(_one(token), BaskVault.Reason.Feed, token);
        feed[0].set(100e8, vm.getBlockTimestamp() - 26 hours - 1);
        _status(_one(token), BaskVault.Reason.NoPoolAge, token);
        feed[0].set(100e8, vm.getBlockTimestamp() - 26 hours);
        _status(_one(token), BaskVault.Reason.None, address(0));
    }

    function testPriceBandBoundariesAndPauseProbe() public {
        address token = address(stock[0]);
        feed[0].set(25e8, vm.getBlockTimestamp());
        _status(_one(token), BaskVault.Reason.None, address(0));
        feed[0].set(25e8 - 1, vm.getBlockTimestamp());
        _status(_one(token), BaskVault.Reason.Band, token);
        feed[0].set(400e8, vm.getBlockTimestamp());
        _status(_one(token), BaskVault.Reason.None, address(0));
        feed[0].set(400e8 + 1, vm.getBlockTimestamp());
        _status(_one(token), BaskVault.Reason.Band, token);
        feed[0].set(100e8, vm.getBlockTimestamp());
        stock[0].setPaused(true);
        _status(_one(token), BaskVault.Reason.OraclePaused, token);
        stock[0].setPaused(false);
        for (uint256 mode = 1; mode <= 3; ++mode) {
            stock[0].setPauseMode(mode);
            _status(_one(token), BaskVault.Reason.OraclePaused, token);
        }
    }

    function testNoPauseInterfaceAtListingDoesNotRequireItLater() public {
        MockToken t = new MockToken(18);
        t.setPauseMode(3);
        MockFeed f = new MockFeed(8, 100e8);
        BaskVault.Action memory a = _action(BaskVault.Kind.List, address(t));
        a.target = address(f);
        uint256 id = _propose(a);
        f.set(100e8, vm.getBlockTimestamp() + 2 days);
        _execute(id);
        assertFalse(vault.asset(address(t)).hasPause);
        _status(_one(address(t)), BaskVault.Reason.None, address(0));
    }

    function testEveryHeldPriceAndEveryUnretiredBalanceRequired() public {
        _deposit(0, 10e18, alice);
        feed[0].setMode(1);
        _status(_one(address(stock[1])), BaskVault.Reason.Feed, address(stock[0]));
        feed[0].setMode(0);
        feed[2].setMode(1);
        _status(_one(address(stock[1])), BaskVault.Reason.None, address(0));
        stock[2].setBalanceMode(1);
        _status(_one(address(stock[1])), BaskVault.Reason.BalanceUnreadable, address(stock[2]));
    }

    function testFreshnessAndDuplicateUnlistedClosedReasons() public {
        for (uint256 i; i < 3; ++i) {
            feed[i].set(100e8, vm.getBlockTimestamp() - 1 hours - 1);
        }
        _status(_one(address(stock[0])), BaskVault.Reason.Freshness, address(0));
        feed[2].set(100e8, vm.getBlockTimestamp() - 1 hours);
        _status(_one(address(stock[0])), BaskVault.Reason.None, address(0));
        address[] memory ts = new address[](2);
        ts[0] = address(stock[0]);
        ts[1] = ts[0];
        _status(ts, BaskVault.Reason.Duplicate, ts[0]);
        _status(_one(bob), BaskVault.Reason.Unlisted, bob);
        vm.prank(GUARDIAN);
        vault.close(address(stock[0]));
        _status(_one(address(stock[0])), BaskVault.Reason.Closed, address(stock[0]));
    }

    function testPoolLiquidityQuotePriceDeviationAndStaleness() public {
        MockToken quote = new MockToken(18);
        MockFeed quoteFeed = new MockFeed(8, 100e8);
        MockPool pool = new MockPool(address(stock[0]), address(quote));
        BaskVault.Action memory a = _action(BaskVault.Kind.Pool, address(stock[0]));
        a.pool = address(pool);
        a.quoteFeed = address(quoteFeed);
        a.value = 1e10;
        uint256 id = _propose(a);
        quoteFeed.set(100e8, vm.getBlockTimestamp() + 2 days);
        _execute(id);
        _status(_one(address(stock[0])), BaskVault.Reason.None, address(0));
        BaskVault.AssetView[] memory views = vault.allAssets();
        assertEq(views[0].poolPrice, 100e18);
        quoteFeed.set(103e8, vm.getBlockTimestamp());
        _status(_one(address(stock[0])), BaskVault.Reason.None, address(0));
        quoteFeed.set(103e8 + 1, vm.getBlockTimestamp());
        _status(_one(address(stock[0])), BaskVault.Reason.Pool, address(stock[0]));
        quoteFeed.set(97e8, vm.getBlockTimestamp());
        _status(_one(address(stock[0])), BaskVault.Reason.None, address(0));
        quoteFeed.set(97e8 - 1, vm.getBlockTimestamp());
        _status(_one(address(stock[0])), BaskVault.Reason.Pool, address(stock[0]));
        quoteFeed.set(100e8, vm.getBlockTimestamp() - 80 hours - 1);
        _status(_one(address(stock[0])), BaskVault.Reason.Pool, address(stock[0]));
        quoteFeed.set(100e8, vm.getBlockTimestamp());
        pool.set(0, uint160((uint256(1800) << 128) / 1e8));
        _status(_one(address(stock[0])), BaskVault.Reason.Pool, address(stock[0]));
        for (uint256 mode = 1; mode <= 3; ++mode) {
            pool.setMode(mode);
            _status(_one(address(stock[0])), BaskVault.Reason.Pool, address(stock[0]));
        }
    }

    function testPoolAllowsMaxAgeAndRemovingPoolRestoresNoPoolAge() public {
        _alwaysOpen();
        MockToken quote = new MockToken(18);
        MockFeed qf = new MockFeed(8, 100e8);
        MockPool pool = new MockPool(address(stock[0]), address(quote));
        BaskVault.Action memory a = _action(BaskVault.Kind.Pool, address(stock[0]));
        a.pool = address(pool);
        a.quoteFeed = address(qf);
        uint256 id = _propose(a);
        qf.set(100e8, vm.getBlockTimestamp() + 2 days);
        _execute(id);
        feed[0].set(100e8, vm.getBlockTimestamp() - 80 hours);
        _status(_one(address(stock[0])), BaskVault.Reason.None, address(0));
        a.pool = address(0);
        a.quoteFeed = address(0);
        _execute(_propose(a));
        feed[0].set(100e8, vm.getBlockTimestamp() - 80 hours);
        _status(_one(address(stock[0])), BaskVault.Reason.NoPoolAge, address(stock[0]));
    }

    function testConsultNegativeRoundingAndCumulativeWrap() public {
        OracleHarness harness = new OracleHarness();
        MockPool pool = new MockPool(address(stock[0]), address(stock[1]));
        pool.set(-1801, uint160((uint256(1800) << 128) / 1e12));
        (bool ok, int24 tick, uint128 liq) = harness.consult(address(pool), 1800);
        assertTrue(ok);
        assertEq(tick, -2);
        assertGe(liq, 1e12 - 1);
        pool.setStarts(type(int56).min + 100, type(uint160).max - 100);
        (ok, tick, liq) = harness.consult(address(pool), 1800);
        assertTrue(ok);
        assertEq(tick, -2);
        assertGe(liq, 1e12 - 1);
        pool.set(0, 0);
        (ok,,) = harness.consult(address(pool), 1800);
        assertFalse(ok);
        pool.set(887273 * 1800, 1);
        (ok,,) = harness.consult(address(pool), 1800);
        assertFalse(ok);
    }

    function testPoolOrientationAndDifferentDecimals() public {
        _alwaysOpen();
        MockToken t = new MockToken(6);
        MockToken q = new MockToken(18);
        MockFeed f = new MockFeed(8, 100e8);
        MockFeed qf = new MockFeed(8, 1e8);
        // Stock Token is token1. Raw quote per raw stock is about 1e14.
        MockPool pool = new MockPool(address(q), address(t));
        pool.set(-322378 * 1800, uint160((uint256(1800) << 128) / 1e12));
        BaskVault.Action memory a = _action(BaskVault.Kind.List, address(t));
        a.target = address(f);
        a.pool = address(pool);
        a.quoteFeed = address(qf);
        a.value = 1e10;
        uint256 id = _propose(a);
        f.set(100e8, vm.getBlockTimestamp() + 2 days);
        qf.set(1e8, vm.getBlockTimestamp() + 2 days);
        _execute(id);
        _status(_one(address(t)), BaskVault.Reason.None, address(0));
        t.mint(alice, 1e6);
        vm.prank(alice);
        t.approve(address(vault), 1e6);
        vm.prank(alice);
        uint256 shares = vault.deposit(_one(address(t)), _amount(1e6), alice, 0, vm.getBlockTimestamp());
        assertEq(shares, 100e18 - 1e15);
    }

    function testFuzzValueAcrossTokenAndFeedDecimals(uint8 td, uint8 fd) public {
        td = uint8(bound(td, 0, 18));
        fd = uint8(bound(fd, 0, 18));
        MockToken t = new MockToken(td);
        MockFeed f = new MockFeed(fd, int256(123 * 10 ** uint256(fd)));
        BaskVault.Action memory a = _action(BaskVault.Kind.List, address(t));
        a.target = address(f);
        uint256 id = _propose(a);
        f.set(f.answer(), vm.getBlockTimestamp() + 2 days);
        _execute(id);
        uint256 units = 7 * 10 ** uint256(td);
        t.mint(alice, units);
        vm.prank(alice);
        t.approve(address(vault), units);
        vm.prank(alice);
        uint256 shares = vault.deposit(_one(address(t)), _amount(units), alice, 0, vm.getBlockTimestamp());
        assertEq(shares, 861e18 - 1e15);
    }
}
