// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library NewYorkTime {
    /// @dev US rule: second Sunday in March at 07:00 UTC through first Sunday
    /// in November at 06:00 UTC. Civil calendar arithmetic, with no external clock.
    function weekSecond(uint256 timestamp, uint256 dst) internal pure returns (uint256) {
        uint256 offset = 5 hours;
        if (dst == 2 || (dst == 0 && daylight(timestamp))) offset = 4 hours;
        // Unix epoch was Thursday. Addition avoids underflow near the epoch.
        return (timestamp + 4 days + 1 weeks - offset) % 1 weeks;
    }

    function daylight(uint256 timestamp) internal pure returns (bool) {
        uint256 daysSinceEpoch = timestamp / 1 days;
        uint256 year = 1970 + daysSinceEpoch / 365;
        while (jan1(year) > daysSinceEpoch) --year;
        uint256 start = jan1(year);
        uint256 march = start + 59 + (leap(year) ? 1 : 0);
        uint256 november = start + 304 + (leap(year) ? 1 : 0);
        uint256 marchSunday = march + (7 - (march + 4) % 7) % 7 + 7;
        uint256 novemberSunday = november + (7 - (november + 4) % 7) % 7;
        return timestamp >= marchSunday * 1 days + 7 hours && timestamp < novemberSunday * 1 days + 6 hours;
    }

    function jan1(uint256 year) private pure returns (uint256) {
        uint256 y = year - 1;
        return 365 * (year - 1970) + y / 4 - y / 100 + y / 400 - 477;
    }

    function leap(uint256 year) private pure returns (bool) {
        return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    }
}
