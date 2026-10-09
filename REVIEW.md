# Local adversarial review

This records the implementation's local checks, not an independent audit. The supplied protected deployment test was read as input; its runtime size and forbidden-opcode checks are reproduced without environment variables in `testDeploymentDefaultsAndRuntime`. No fork, deployment, broadcast, wallet access, Slither, or Mythril run was performed.

## Exit-path attacks

`test/Redemption.t.sol` exercises paused deposits, closed assets, a zero NAV cap, stale/unreadable feeds, paused Stock Token oracles, blocked transfers, exhausted call gas, malformed or missing balance return data, disappearance of token code, false returns after moving balances, wrong transfer debits, empty successful return data, large return data, and reentrant callbacks. Failed isolated payments preserve custody and become claims; successful direct legs satisfy the exact debit check. Failed claims preserve the recorded debt. Minimum-output and deadline failures are caller constraints, not asset-health checks.

Claims are tested with both payment budgets at their minimum and a token requiring more gas for `balanceOf` than the configured budget. They succeed because claims do not use either admin-set budget. The `pay` helper can only be called by the vault and runs under the outer entry point's reentrancy lock.

`test/RedemptionGas.t.sol` cools the vault and token storage before each measured redemption, uses complete per-asset slippage arrays from the preview, forwards at most 27,950,000 gas, and additionally counts the transaction's intrinsic and calldata gas. The figures below are gas units, including that transaction allowance, under the pinned Cancun EVM configuration. Fixture construction gas is outside the measurement.

| Scenario | Measured gas |
| --- | ---: |
| 250 unreadable assets, default settings | 26,774,316 |
| 250 blocked assets with balances consuming almost their entire read budget | 26,477,316 |
| 50 attempted direct payments among 250 assets, exhausting payment gas | 18,142,654 |
| 350 assets at the minimum balance-read budget | 26,960,100 |
| 50 assets at the maximum balance-read budget, newly enabled fee recipient | 27,947,881 |
| Same maximum read budget, maximum uint256 managed balances and full-precision division | 27,990,581 |
| 254 attempted direct payments among 350 assets with minimum call budgets | 24,669,800 |
| Maximum payment budget with 47 funded and 303 empty assets | 27,539,103 |

The maximum-balance test supplies actual full-width minimum amounts, so its calldata is substantially more expensive than zero minima. These tests cover the allowed setting corners as well as the requested 250-asset default. Arbitrarily oversized caller arrays, chain-specific fee accounting, and future EVM gas repricing are outside these measurements.

## Repairs made during checking

* Traversing all assets twice made valid extreme settings exceed the gas budget. The vault now maintains an internal two-word bitmap and count of nonzero managed balances. Empty assets need no token or accounting storage reads on redemption. Loss recognition, resync, removal/reordering, deposits and redemption maintain this cache; dedicated tests exercise clearing, restoring and moving entries. The settings bounds imply at most 350 assets, so two words cover every permitted configuration.
* Per-leg queued-debt logs consumed unnecessary exit gas. A single `Redeem` event records every leg; `Paid` events identify which legs were delivered. Other nonzero legs were queued. No payment or minimum check was removed.
* A zero-valued reentrancy sentinel incurred a fresh storage write on every entry. The initialized nonzero sentinel preserves the same exclusion behavior with lower execution gas.
* Capping claim balance reads by `balanceGas` would have allowed a setting change to prevent a legitimate claim. Claim balance reads and payments now receive caller-supplied gas; the direct redemption payment remains bounded by its outer `payGas` call.
* The compiler initially shared the ERC-20 Transfer topic in an appended data section. The supplied opcode scanner interpreted a byte in that data as a forbidden opcode. Computing the standard topic in scratch memory avoids the shared data section. The emitted topic is separately tested against the standard ERC-20 event.

## Other checks

* Deposits: initial locked shares, fee rounding, NAV/share rounding, donations excluded from NAV, exact pulls, atomic multi-token failure, cap enforcement, zero NAV, duplicate/closed/unlisted inputs, every unretired balance, and every held price.
* Accounting: fuzzed deposits/redemptions and conservation, queued debt excluded from backing and resync, partial claims, surplus-only resync, delayed loss recognition, recovery, larger-deficit timer resets, and record clearing.
* Administration: role authorization, two-step ownership, invalid/equal roles, guardian replacement cancellation restrictions, proposal delay/expiry, repeated close invalidating reopen, cap lowering invalidating raises, execution-time revalidation, permanent retirement, proposal invalidation, removal and relisting.
* Pricing: positive/future/stale/malformed feeds, age and price-band boundaries, optional pause detection, pool liquidity and deviation boundaries, quote-feed age, pool removal, quote orientation and differing decimals, negative mean-tick rounding, and cumulative wraparound.
* Calendar: independent Python `zoneinfo` fixtures for every New York daylight transition from 2026 through 2040, both sides of each transition, forced standard/daylight modes, and weekly trading-hour endpoints.
* Build: compiler/version settings, application runtime size, forbidden opcodes, and formatting.

## Accepted behavior and remaining responsibility

The review preserves the five accepted tradeoffs: feed-lag profit within deviation tolerance, owner responsibility for true feed/pool pairings, no concentration limit, thin-pool manipulation stopping deposits, and later depositors sharing retired custody. No mechanism was added to change these economics.

Underlying issuers can prevent delivery or confiscate custody; owed accounting cannot make an unavailable Stock Token transferable. The owner must validate the real launch addresses, observation windows, liquidity threshold and feed units before finalizing genesis. No production-chain addresses other than the supplied owner and guardian are assumed. Release with funds still needs the requested independent contributor review of the contracts and actual configuration.
