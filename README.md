# Basket Protocol

Basket is an index vault for **Stock Tokens** on Robinhood Chain. `BaskVault` is also the ERC-20 share: **Basket / BASK / 18 decimals**. It starts with zero supply. Deposits mint shares and redemptions burn shares; there is no supply cap, separate launch token, pool, website, proxy, upgrade path, rescue, or sweep.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, optimizer **200 runs**, **via IR**, **Cancun**, and `bytecode_hash = "none"`. The compiler must be installed in the execution environment. All Solidity dependencies are ordinary vendored files. Builds and tests need no network, fork, environment variables, FFI, or filesystem cheatcode permissions.

The application fits within the 24,576-byte runtime limit, so its views remain in `BaskVault`; no `BaskLens` is needed. The deployment test also scans runtime bytes for forbidden opcodes. See [REVIEW.md](REVIEW.md) for local adversarial checks and their limits.

## Deployment

`launch.json` deploys only `BaskVault(address owner_, address guardian_)` with these literal arguments:

| Argument | Address |
| --- | --- |
| `owner_` | `0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3` |
| `guardian_` | `0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68` |

Zero or equal roles revert. Ownership does not depend on the factory or constructor caller. No transactions, keys, or broadcasts are part of this project.

## After launch

The brief supplies no Stock Token, feed, pool, quote-feed, liquidity threshold, or fee-recipient addresses. These are intentionally configured by the owner using the specified genesis and proposal flows; none is guessed or fixed to a substitute contract.

1. Verify each intended Stock Token and its actual USD feed on the launch chain. Verify token and feed decimals, feed units, freshness, the optional `oraclePaused()` interface, and the pool's pair and observation history. The owner is responsible for pairing assets with their true feeds and pools.
2. Call `listGenesis(token, feed, pool, quoteFeed, minLiquidity)` for at least three assets. This is immediate and owner-only until genesis is finalized. A pool-less listing explicitly uses `(pool, quoteFeed, minLiquidity) = (address(0), address(0), 0)`. With a pool, supply its other token's USD feed and the chosen minimum harmonic mean liquidity in the pool's raw liquidity units.
3. Call `finalizeGenesis()` once. Deposits then become available subject to hours, pause, prices, freshness, balances, and the NAV cap. `finalizeGenesis` does not undo an existing deposit pause.
4. If fees are wanted, propose `Kind.FeeRecipient` with the actual recipient in `target`, then execute after the delay. Fees remain off while unset. Once set, the recipient can be changed but cannot be cleared or be the vault. The fee rate is fixed at 50 basis points.
5. Monitor oracle freshness, pool observations and liquidity, token implementation changes, custody deficits, pending proposals, and queued claims. Use `close` or `pauseDeposits` when necessary; these affect deposits only. Monitor New York trading hours and use the timelocked `Dst` setting if the applicable daylight rule changes.

## Accounting and user calls

`managed[token]` is the accounting balance. NAV never values `balanceOf(vault)`: unsolicited transfers do not buy shares or change NAV. A timelocked resync can add only surplus above both managed balances and outstanding claims.

`deposit(tokens, amounts, receiver, minSharesOut, deadline)` checks the entire unretired basket for readable balances and deficits, and validates prices for every held asset and every input. Input tokens must be unique, open and listed, amounts positive, and the receiver neither zero nor the vault. Every pull must increase custody by exactly its requested amount. Multi-token deposits are atomic.

USD values use 18 decimals and round down: `amount * answer * 1e18 / 10^(tokenDecimals + feedDecimals)`. Gross shares are the deposit value at zero supply, otherwise `value * totalSupply / NAV`, rounded down. Nonzero supply with zero NAV reverts. The fixed deposit fee is rounded up and minted to the configured fee recipient. The first deposit also locks `1e15` shares at `address(0xdEaD)`; `minSharesOut` is compared to the receiver's actual shares after both deductions. NAV plus deposit value must fit the cap, initially USD 1,000,000.

`redeem(shares, receiver, minAmountsOut, deadline)` reads no prices and ignores deposit pauses, hours, asset closure, retirement, and all feed/pool conditions. The rounded-up share fee is transferred to the fee recipient; net shares are burned. A tiny redemption can consist entirely of fee shares. Each leg is:

```text
available = max(balance - totalOwed, 0), or managed if balance is unreadable
leg = min(managed, available) * netShares / totalSupplyBeforeBurn
```

The balance read uses `balanceGas`, copies only 32 bytes, and cannot make redemption fail through token revert data or unreadability. No automatic write-down changes the residual managed amount. If the number of assets with managed balances is at most `directLimit`, each nonzero leg gets an isolated external self-call with `payGas`. That call requires a successful transfer returning nothing or `true`, and an exact vault balance decrease. A failed call rolls back that entire payment and records debt. Above `directLimit`, all nonzero legs become debt. Retired assets participate equally in redemption.

The returned leg array and `minAmountsOut` use **the full current `assetTokens()` order**, including zero and retired legs. Missing minimum entries mean zero; extra entries beyond the asset list are ignored. Removal swaps the last asset into the removed position, so re-read the ordering before preparing a transaction. `Redeem` logs all amounts; `Paid` identifies successfully delivered legs, and the remaining nonzero legs were added to `owed[receiver][token]` and `totalOwed[token]`.

`claim(tokens, to)` spends only the caller's debt and can redirect delivery to any nonzero address. Each payment is `min(callerDebt, actualVaultBalance)`. Both the balance reads and the isolated payment use caller-supplied gas without `balanceGas` or `payGas` caps. A failed claim transaction preserves debt. Callers can choose individual assets to avoid an unavailable token in a batch. Claims have priority over managed backing when custody is short and are paid in transaction order, not proportionally among creditors.

All user-facing mutations are reentrancy guarded and emit events. `pay` is a vault-only implementation entry point under the enclosing operation's lock. Token callbacks cannot enter it or another mutation. A blocked or changed token may make delivery impossible, but redemption still creates the accounting claim; it cannot force the issuer to transfer.

## Prices and hours

The main feed must succeed within `feedGas`, return a positive answer, have a nonfuture update within `maxAge`, and stay in `[centre / band, centre * band]`. If the listing probe decoded a boolean `oraclePaused()`, each price check requires a successful false result within `pauseGas`.

Without a pool, `noPoolAge` also applies. With a pool, the bounded `observe([poolWindow, 0])` read uses Uniswap v3 arithmetic: negative ticks round toward negative infinity and cumulative differences wrap at their specified widths. Harmonic mean liquidity must meet the threshold. The mean-tick quote for one whole Stock Token is converted from raw quote units to USD using the positive, nonfuture, sufficiently recent quote feed. The absolute difference from the main USD price must be at most `poolDeviation` basis points of the main price. Quote-at-tick and USD conversions round down.

Freshness counts positive, successfully read, unretired main feeds with nonfuture updates within both `maxAge` and `freshHours`. A zero-managed, unselected asset needs no other price check, but its balance must still be readable. A retired asset is excluded from **every deposit health, freshness and NAV check**, even when it still has managed balances. An explicitly supplied retired input is closed and rejected.

Hours are an inclusive start and exclusive end measured from Sunday 00:00 New York local time. Defaults run Sunday 20:00 through Friday 20:00. `(0, 0)` is always open. `Dst = 0` implements the US second-Sunday-in-March / first-Sunday-in-November rule, including transition instants; `1` fixes UTC−5 and `2` fixes UTC−4. Only `block.timestamp` is used.

## Administration

The owner can immediately list genesis assets, finalize genesis, close assets, pause/unpause deposits, and lower `NAV_CAP`. Lowering the cap invalidates all pending raises. The guardian can pause deposits, close assets, and cancel proposals except its own replacement. Closing always invalidates older reopen proposals, even if the asset was already closed.

Ownership transfer is `transferOwnership(next)` followed by `acceptOwnership()` from the nominee. There is no renunciation. The guardian cannot become owner; a guardian proposal is checked again at execution so the roles cannot become equal through a pending ownership transfer.

All other changes use `propose(Action)` and owner-only `execute(id)`. Execution opens at creation plus **2 days** and closes at creation plus **9 days** (exclusive). Validation runs at proposal and execution. Owner or guardian cancellation makes the proposal unusable; the guardian cannot cancel any `Kind.Guardian` proposal.

| `Kind` | Relevant `Action` fields and execution behavior |
| --- | --- |
| `List` | `token`, `target = feed`, `pool`, `quoteFeed`, `value = minLiquidity`; lists open, detects pause interface, sets centre from execution answer |
| `Feed` | `token`, `target = new feed`; checks feed uniqueness and decimals, resets centre to execution answer |
| `Recentre` | `token`; sets centre to fresh execution answer |
| `Reopen` | `token`; valid only if no later close invalidated it |
| `Retire` | `token`; requires closed at both proposal and execution; permanently closes, frees the feed, invalidates all older asset proposals |
| `Pool` | `token`, `pool`, `quoteFeed`, `value = minLiquidity`; the all-zero pool tuple explicitly removes the pool |
| `Resync` | `token`; adds positive custody surplus after managed and owed balances |
| `Guardian` | `target = new guardian`; nonzero and distinct from owner |
| `RaiseCap` | `value = new USD18 cap`; strictly raises, at most `10_000_000_000e18` |
| `FeeRecipient` | `target = recipient`; nonzero and not the vault |
| `Setting` | `setting`, `value`; `Hours` uses `value2` for its end |

Unused action fields have no effect. Retired assets accept only new resync proposals. Anyone can `removeRetired(token)` once managed and total owed are both zero; it may then be listed again. Removal also invalidates remaining proposals for that listing incarnation. Retirement never removes custody and never excludes its tokens from redemption: **depositors after retirement share those tokens**.

| Setting | Initial value | Bounds |
| --- | --- | --- |
| `Band` | 4 | 2–100 |
| `MaxAge` | 80 hours | 1 hour–30 days, supplied in seconds |
| `NoPoolAge` | 26 hours | 1 hour–30 days, supplied in seconds |
| `FreshCount` | 1 | 0–10 |
| `FreshHours` | 1 | 1–48, supplied in hours |
| `Hours` | 72000, 504000 | start < end ≤ 604800, or 0, 0 |
| `Dst` | 0 | 0–2 |
| `PoolWindow` | 1800 seconds | 300–86400 |
| `PoolDeviation` | 300 bps | 50–2000 |
| `FeedGas`, `PauseGas` | 100000 each | 20000–500000 each |
| `PoolGas` | 150000 | 20000–500000 |
| `BalanceGas` | 50000 | 20000–500000 |
| `PayGas` | 250000 | 20000–500000 |
| `MaxAssets` | 250 | at least the current asset count, and the gas constraint below |
| `DirectLimit` | 50 | the gas constraint below; zero queues every nonzero leg |

Every setting change must preserve:

```text
maxAssets * (balanceGas + 60_000) <= 28_000_000
directLimit * (balanceGas + payGas + 70_000) <= 28_000_000
```

No admin path moves custody, creates shares, changes the fee rate, upgrades code, or pauses redemption or claims. Lower call budgets can cause redemption to queue payments, but claims do not use those budgets.

## Deficits and views

Anyone can `flagDeficit(token)`. A larger observed shortfall records a new amount and timestamp; a smaller still-positive shortfall leaves the record unchanged; full recovery clears it. After seven days, anyone can `recognizeLoss(token)`, reducing managed by the lesser of the recorded and current shortfall, then clearing the record. Unreadable balances cannot establish or clear a deficit. Successful deposits clear all unretired records.

`allAssets()` returns configuration, main answer and update time, USD18 pool price when available, managed, owed, readable-balance status, shortfall, and price reason. `settings()`, `assetTokens()`, `asset(token)`, and `assetCount()` expose configuration and ordering. `previewDeposit` applies deposit health/cap checks and returns receiver shares, fee, input value and pre-deposit NAV. `previewRedeem` returns legs, share fee and whether direct payments will be attempted, without prices; actual delivery can still become debt. `depositStatus(tokens)` returns the first health reason and asset at fault; it cannot check amounts, receiver, deadline, or slippage absent from its arguments.

`proposal(id)` includes action data and whether it is still pending. `pendingProposals(first, last)` returns pending IDs in an inclusive bounded range, including those still waiting for their delay. Expiry and epoch invalidation are reflected without an unbounded state-changing cleanup loop.

## Trust assumptions

The requested design accepts profit from feed lag within the pool deviation tolerance, owner responsibility for correct feed/pool pairings, no per-asset concentration cap, thin-pool manipulation stopping deposits, and later depositors sharing retired custody. There is no automatic portfolio rebalance or trading. Token issuers and chain operation remain external dependencies; the vault cannot bypass issuer transfer restrictions or chain censorship. Asset/feed decimals are captured when configured.

This implementation has local success, failure, fuzz, calendar, opcode and adversarial gas tests. It has not received an independent security audit. An independent contributor should review the final contracts and actual launch configuration before release with funds.
