// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Copies only the requested output, even if an upgraded dependency returns a data bomb.
library BoundedCall {
    function read(address target, bytes memory input, uint256 gasLimit, uint256 size)
        internal
        view
        returns (bool ok, bytes memory output)
    {
        output = new bytes(size);
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 32), mload(input), add(output, 32), size)
            ok := and(ok, iszero(lt(returndatasize(), size)))
        }
    }

    function word(address target, bytes memory input, uint256 gasLimit) internal view returns (bool ok, uint256 value) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, target, add(input, 32), mload(input), 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            value := mload(0)
        }
    }

    function transfer(address token, bytes memory input) internal returns (bool ok) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(gas(), token, 0, add(input, 32), mload(input), 0, 32)
            ok := and(ok, or(iszero(returndatasize()), and(iszero(lt(returndatasize(), 32)), eq(mload(0), 1))))
        }
    }
}
