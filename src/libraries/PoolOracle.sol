// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BoundedCall} from "./BoundedCall.sol";
import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";

/// @dev Uniswap v3 OracleLibrary consult/getQuoteAtTick arithmetic, ported to 0.8.26
/// with bounded calls and explicit malformed-output handling. Cumulative deltas wrap.
library PoolOracle {
    function consult(address pool, uint32 window, uint256 gasLimit)
        internal
        view
        returns (bool ok, int24 meanTick, uint128 liquidity)
    {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        bytes memory data;
        (ok, data) = BoundedCall.read(pool, abi.encodeWithSignature("observe(uint32[])", ago), gasLimit, 256);
        if (!ok) return (false, 0, 0);
        uint256 off0;
        uint256 off1;
        uint256 len0;
        uint256 len1;
        int256 t0;
        int256 t1;
        uint256 s0;
        uint256 s1;
        assembly ("memory-safe") {
            off0 := mload(add(data, 32))
            off1 := mload(add(data, 64))
            len0 := mload(add(data, 96))
            t0 := mload(add(data, 128))
            t1 := mload(add(data, 160))
            len1 := mload(add(data, 192))
            s0 := mload(add(data, 224))
            s1 := mload(add(data, 256))
        }
        if (
            off0 != 64 || off1 != 160 || len0 != 2 || len1 != 2 || t0 != int56(t0) || t1 != int56(t1)
                || s0 > type(uint160).max || s1 > type(uint160).max
        ) {
            return (false, 0, 0);
        }
        int56 dt;
        uint160 ds;
        unchecked {
            dt = int56(t1) - int56(t0);
            ds = uint160(s1) - uint160(s0);
        }
        if (ds == 0) return (false, 0, 0);
        int56 tick = dt / int56(uint56(window));
        if (dt < 0 && dt % int56(uint56(window)) != 0) --tick;
        if (tick < -887272 || tick > 887272) return (false, 0, 0);
        uint256 liq = (uint192(window) * type(uint160).max) / (uint192(ds) << 32);
        if (liq > type(uint128).max) return (false, 0, 0);
        return (true, int24(tick), uint128(liq));
    }

    function quote(int24 tick, uint128 amount, bool baseIsToken0) internal pure returns (uint256) {
        uint160 sqrt = TickMath.getSqrtRatioAtTick(tick);
        if (sqrt <= type(uint128).max) {
            uint256 ratio = uint256(sqrt) * sqrt;
            return baseIsToken0 ? FullMath.mulDiv(ratio, amount, 1 << 192) : FullMath.mulDiv(1 << 192, amount, ratio);
        }
        uint256 ratio128 = FullMath.mulDiv(sqrt, sqrt, 1 << 64);
        return baseIsToken0 ? FullMath.mulDiv(ratio128, amount, 1 << 128) : FullMath.mulDiv(1 << 128, amount, ratio128);
    }
}
