# Lifecycle v1

This is new immutable market code and a new factory/vault deployment. Existing
markets retain their original behavior. No user collateral is migrated.

Creation publishes a company name and an immutable market type. New Pre-IPO tags
are `PRIPO:` followed by 2–10 uppercase alphanumeric characters. External markets
use a governor-published directory of already approved feeds. One market per feed
and symbol is still enforced by the factory. Wallet display names are self-selected
labels; the address remains the identity and authority.

The new launch has a 1,000 USDC minimum bond, a 20% creator share, an insurance cap
of ten times the initial bond and a starting OI cap of fifty times that bond. Excess
insurance credits go to the global backstop. The OI cap falls when insurance falls
below the initial bond and does not grow above its initial value. Curve reserves
are derived so buys worth fifteen times the initial bond move the initial mark
approximately +1%, conservatively rounded. Existing margin, side-exposure, funding,
2x/5x leverage and 2,000 USDC per-user engine limits continue to apply.

Scoped operators enforce a combined position limit at the post-fill mark and an
entry-notional/collateral leverage ceiling. Lower leverage locks additional owner
collateral atomically. Market allowlists use the existing sorted-pair Merkle proof.
Daily loss is gross realized debits from PnL, funding, fees, penalties and ADL across
the owner's markets, measured from the first scoped-key issuance onward. Credits
do not replenish it, and key replacement/revocation cannot reset it. The counter
resets on the first debit of a new UTC day. Reaching the budget prevents new entries;
it does not guarantee a maximum eventual loss. Scoped closes do not consume opening
allowance or fail solely because the daily budget is exhausted. Expiry, revocation,
market scope and close permission still apply. Owners can always act for themselves.
Older immutable implementations reject scoped-key use through a version check.

Optimistic terminal settlement is available only to the new oracleless markets.
The creator declares an event/time/source; any proposer can post a price after that
time or after thirty days without a price refresh. Proposal freezes trading and
funding. The proposal and dispute bonds are each 2,500 USDC. The dispute window is
24 hours; a dispute opens a 48-hour window for three of five distinct council votes.
Council members must choose one of the two bonded prices. The winner receives its
bond plus half the losing bond; the other half funds market insurance. Uncontested
finalization returns the proposal bond without an insurance-funded bonus.

If the council times out, both bonds are refundable and anyone can finalize using
the market TWAP captured when the proposal froze trading. This is the explicit
liveness fallback; it is not an external oracle guarantee. Council composition and
this fallback must be disclosed for every deployment. Bonds use pull claims to the
wallet. Position payouts use the existing whole-book loss/haircut/capital waterfall;
they remain locked until the owner claims them into free vault balance. Claims are
single-use. Keeper-triggered forced settlement retains its existing automatic release.

AccountActivity records signed WAD economic deltas at the authoritative vault:
0 PnL (including terminal haircut), 1 funding, 2 trading fees, 3 penalties,
4 ADL redistribution, 5 debt coverage, 6 keeper/rounding rewards. Deposits, withdrawals,
margin transfers and protocol capital are not trading PnL. Creator/referral income
remains separately indexed. PositionSettled records the optimistic final valuation
before the live position is deleted. Indexer rollback must undo these projections
with their source events.

These additions are locally tested and intended for the isolated Tenderly demo;
their presence does not establish a completed independent security audit.

## Isolated deployment evidence

The completed fork deployment is recorded in
[`deployments/tenderly-lifecycle.json`](../deployments/tenderly-lifecycle.json),
with a separate factory/vault/resolver, two active markets and verified runtime
hashes. The existing Tenderly deployment was retained. The runner validates its
simulated plan, new deployments and reused deterministic library code separately.
It does not migrate user collateral.

[`deployments/tenderly-lifecycle-smoke.json`](../deployments/tenderly-lifecycle-smoke.json)
records the separate PRIPO:CHECK market: scoped operator open/close/revoke, proposal,
dispute, three council votes, position claim and bond claim. The council addresses
are controlled impersonated demo accounts. The vote window and refund behavior
are protocol features; the demo does not establish independent governance.

Tenderly assigned the same transaction hash to the three unsigned council calls
at blocks 111,799,246 / 248 / 250 and retains only the last receipt in its log API.
Historical state verifies vote bitmaps 1 / 3 / 7. The indexer's accounting report
records this source limitation explicitly. The shared runner now gives these demo
senders distinct gas fields to avoid another unsigned hash collision.

The fork reports RPC chain ID 999143 and EVM CHAINID 1. No typed-signature or Safe
flow is claimed. The real signed Pyth update path and oracle guards are preserved;
only empty-book demo setup advances the fork clock. Public-chain deployment and
an independent audit are separate work.
