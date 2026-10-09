// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {VaultTestBase} from "./VaultTestBase.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {NewYorkTime} from "../src/libraries/NewYorkTime.sol";

contract NewYorkTimeTest is VaultTestBase {
    // Independent fixtures: Python zoneinfo, America/New_York, hourly UTC transitions.
    function testUSDaylightBoundaries2026Through2040() public pure {
        uint256[15] memory starts = [
            uint256(1772953200),
            1805007600,
            1836457200,
            1867906800,
            1899356400,
            1930806000,
            1962860400,
            1994310000,
            2025759600,
            2057209200,
            2088658800,
            2120108400,
            2152162800,
            2183612400,
            2215062000
        ];
        uint256[15] memory ends = [
            uint256(1793512800),
            1825567200,
            1857016800,
            1888466400,
            1919916000,
            1951365600,
            1983420000,
            2014869600,
            2046319200,
            2077768800,
            2109218400,
            2140668000,
            2172722400,
            2204172000,
            2235621600
        ];
        for (uint256 i; i < starts.length; ++i) {
            uint256 a = starts[i];
            uint256 b = ends[i];
            assertFalse(NewYorkTime.daylight(a - 1));
            assertTrue(NewYorkTime.daylight(a));
            assertTrue(NewYorkTime.daylight(b - 1));
            assertFalse(NewYorkTime.daylight(b));
            assertEq(NewYorkTime.weekSecond(a - 1, 0), 2 hours - 1);
            assertEq(NewYorkTime.weekSecond(a, 0), 3 hours);
            assertEq(NewYorkTime.weekSecond(b - 1, 0), 2 hours - 1);
            assertEq(NewYorkTime.weekSecond(b, 0), 1 hours);
            assertEq(NewYorkTime.weekSecond(a, 1), 2 hours);
            assertEq(NewYorkTime.weekSecond(b, 2), 2 hours);
            assertFalse(NewYorkTime.daylight(a - 60 days));
            assertTrue(NewYorkTime.daylight(a + 60 days));
        }
    }

    function testDefaultWeeklyHoursAndAlwaysOpen() public {
        // Sunday 2026-09-20 23:59:59 UTC = Sunday 19:59:59 in New York.
        vm.warp(1789948799);
        assertFalse(vault.insideHours());
        vm.warp(1789948800);
        assertTrue(vault.insideHours());
        // Saturday 00:00 UTC = Friday 20:00 in New York.
        vm.warp(1790380799);
        assertTrue(vault.insideHours());
        vm.warp(1790380800);
        assertFalse(vault.insideHours());
        _alwaysOpen();
        assertTrue(vault.insideHours());
        vm.warp(vm.getBlockTimestamp() + 100 days);
        assertTrue(vault.insideHours());
    }
}
