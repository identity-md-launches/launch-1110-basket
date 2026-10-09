# Additional Basket tests

Run `forge build` and `forge test` from the repository root. All dependencies were
already present. These tests use local Stock Token, feed and pool mocks; they need
no network, fork, environment variables or configuration changes.

`BasketInvariant.t.sol` runs 256 sequences of 96 calls against an explicitly
targeted handler with four actors, including the fee recipient. Every sequence
starts with deposits and queued debt. Random operations include deposits,
redemptions, claims, share transfers, donations, resync, confiscation, loss
recognition, deposit pausing, payment-mode changes and token failures. Unexpected
handler reverts fail the campaign. A deterministic scenario also exercises the
handler's deposits, debt payments, losses and recovery.

The invariants assert:

- Physical custody plus actual payouts and confiscations equals deposited and
  donated Stock Tokens, using independent cumulative counters.
- Managed balances change only through deposits, resync, redemption legs and
  recognized losses. No automatic write-down is assumed.
- Aggregate debt equals the sum of individual debts, and BASK supply equals all
  tracked share balances, including fees and the initial locked shares.
- Every actor can redeem its full balance despite the current token failures,
  stale feeds, pause state and direct-payment setting. This probe restores its
  snapshot so it cannot drain the random campaign's positions.

Handler postconditions additionally check floor rounding, exactly-once payment or
debt creation, redirected claims, and loss timing. The campaign uses fixed $100
prices and 18-decimal Stock Tokens to isolate accounting. It deliberately models
confiscations separately from losses recognized by the vault; ordinary solvency
is not a valid invariant after a confiscation.

`BasketAdversarial.t.sol` adds failure and rollback cases for authorization,
listing revalidation, pool configuration, timelock expiry, first-deposit dust,
batch claims and late redemption slippage. Three properties run 1,000 inputs
each: repeated round trips cannot create value at fixed prices, unaccounted
donations cannot alter share pricing, and every legal setting preserves redeem
and claim access. Existing tests cover decimal combinations, pricing and New
York daylight transitions.

`BasketAssetBoundary.t.sol` exercises sparse managed assets across indices 255
and 256, moving an asset between bitmap words on removal, and restoring a live
bit through resync. Its 250-asset attack combines replaced token code, malformed
and oversized balance responses, blocked transfers, pauses, shortfalls and a
retired holding. It checks exact queued amounts and includes intrinsic calldata
gas in the 28,000,000 gas ceiling. Existing gas tests cover the allowed 350-asset
maximum and extreme call budgets.

These are offline behavior checks. They do not validate real Stock Token feed
pairings or live Robinhood Chain integrations. Retirement and listing lifecycle
coverage is deterministic; the random campaign keeps the asset list fixed.
