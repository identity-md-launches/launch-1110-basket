# Vendored code

All dependencies are ordinary files; no submodules or network resolution are required.

* `lib/forge-std`: Foundry `forge-std` **v1.9.7**, source and upstream license files, from <https://github.com/foundry-rs/forge-std/tree/v1.9.7>. Used only by tests. The version is also recorded in `lib/forge-std/VERSION`.
* `src/libraries/FullMath.sol`: `mulDiv` from Uniswap v3-core **v1.0.0**, MIT, credited upstream to Remco Bloemen. Source: <https://github.com/Uniswap/v3-core/blob/v1.0.0/contracts/libraries/FullMath.sol>. Adapted to Solidity 0.8.26 with intentional modular arithmetic inside `unchecked`, custom errors, memory-safe assembly annotations, and only the used function retained.
* `src/libraries/TickMath.sol`: `getSqrtRatioAtTick` from Uniswap v3-core **v1.0.0**, GPL-2.0-or-later. Source: <https://github.com/Uniswap/v3-core/blob/v1.0.0/contracts/libraries/TickMath.sol>. Adapted to Solidity 0.8.26 and a custom error; unused inverse conversion removed.
* `src/libraries/PoolOracle.sol`: consult and quote arithmetic adapted from Uniswap's [OracleLibrary](https://github.com/Uniswap/v3-periphery/blob/v1.4.4/contracts/libraries/OracleLibrary.sol), GPL-2.0-or-later. Calls and output decoding are bounded, malformed outputs are rejected, signed/unsigned cumulative wrapping is explicit, and the pool's token0/token1 orientation is cached at configuration.

The application is GPL-2.0-or-later; the GPL v2 text is in `LICENSE`. Original SPDX identifiers and attribution are retained. Original project support libraries and tests carry MIT SPDX identifiers.
