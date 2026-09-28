# Pripo — protocol spec: permissionless LP-free markets on Monad

rrSep 26, 2026 · @Favour

## Overview

Pripo is a permissionless, LP-free perpetuals protocol on Monad where anyone deploys a market in one call, prices come from a virtual AMM, and the deployer earns a share of that market's fees forever. Markets are either oracle-fed (any Pyth or Chainlink feed) or oracle-less (pre-IPO companies, priced by the vAMM alone and settled by an optimistic resolver).

**Product goals**

- Be the venue where markets that exist nowhere else get priced: pre-IPO companies, long-tail equities, anything with a feed or a crowd.
- One deposit, any market, human or agent: humans through the UI, agents through operator keys, the SDK and an MCP server.
- No pooled liquidity anywhere. Traders net on the vAMM; fees build the insurance that lets each market grow.
- Fees are the business: taker and settlement fees, creator and referral splits that recruit their own volume, and metered agent infrastructure.

**Phasing.** Phase 1 ships October 13, 2026 as the public launch under capped parameters. Phase 2 lifts caps after external review and adds the equity market-hours engine, cross-margin, gas sponsorship and the first points season. Phase 3 adds tokenized-stock collateral, agent identity tiers and reputation-based margin. Details under Product phases.

**Brand.** Pripo (pre-IPO). Domain pripo.fun, handle @pripodotfun. Markets read as `PRIPO:SPACEX`, the SDK ships as `@pripo/sdk`, the tribe is the Pripos, the verb is "pripo it," and the mascot is a character named Pripo. "Unlisted markets" stays as the descriptor line: Pripo — trade what isn't listed yet.

**Stack**: Solidity 0.8.x, Foundry, EIP-1167 clones, USDC margin, Pyth pull oracles, Envio indexer, TypeScript SDK generated from ABIs.

## Product phases

Three phases, each gated on a measurable exit rather than a date. Phase 1 is the launch this spec's contracts implement; Phases 2 and 3 are specified here so the Phase 1 interfaces leave room for them.

| Phase | Window | Scope | Exit criteria |
| --- | --- | --- | --- |
| 1 — Launch | Sep 26 – Oct 13, 2026 | Vault, market clones, factory, Pyth and null adapters, resolver, referrals, skew discount, operator keys, SDK, MCP server, indexer, keeper, three pre-IPO markets, launch caps | Mainnet live; external review scoped; 500,000 USDC/day volume in any 7-day window |
| 2 — Depth | Oct 2026 – Jan 2027 | Review closed and caps lifted; equity market-hours engine; cross-margin; relayer and gas sponsorship; Chainlink Data Streams adapter; points season 1; Nad.fun auto-markets; Telegram alerts | 5,000,000 USDC/day volume; 50 markets with OI; 25% of volume from operator keys |
| 3 — Prime | Feb – Jun 2027 | Tokenized-stock and multi-asset collateral; ERC-8004 agent tiers; reputation-based margin; creator-role secondary market; governance token decision | 25,000,000 USDC/day volume; insurance backstop covers 30 days of worst-case bad debt |

**Equity market-hours engine (Phase 2).** Oracle-fed equity markets get a state machine driven by the adapter's `marketOpen` flag: `Open → PreClose → Closed → Reopening → Open`.

- PreClose (last 30 minutes before the bell): initial margin for new opens rises to `gapMarginBps` (default 2× normal), max leverage carried into the close is capped at 5x, and `CloseWarning` is emitted for every position above that leverage.
- Closed: index freezes at the last print, funding rate is zero, and the vAMM mark floats on flow alone. This is the product: 24/7 price discovery on a stock that is not trading anywhere else. Health uses the mark TWAP with the closed-hours maintenance margin (default 2× normal). Liquidations continue on the vAMM.
- Reopening: on the first valid print, `gapSettle` marks every position to the print. Positions below maintenance are liquidated at the print, not the vAMM; the gap loss comes from the trader's margin, then market insurance, then the backstop. Funding resumes.
- Weekend and holiday calendars are not stored on-chain; the adapter's flag is the only source of truth.

**Cross-margin (Phase 2).** Optional per user (`enableCrossMargin`). The vault computes `accountHealth = (freeBalance + Σ positionEquity) / Σ notional` across markets and lets a position run below its isolated initial margin while account health holds. Account-level liquidation closes the worst-health position first. Markets keep isolated accounting; the vault adds one cross-contract read of `positionEquity(user)` per open. This is the onchain prime-brokerage story.

**Gas sponsorship (Phase 2).** `openBySig` and `closeBySig` take an EIP-712 order signed by the operator key; a hosted relayer submits and pays gas, recovering cost through a fee markup or x402 metering. Agents never need MON.

**Tokenized-stock and multi-asset collateral (Phase 3).** The vault accepts whitelisted ERC-20s (Anchored stock tokens on Monad, xStocks and AUSD where bridged) with per-asset haircuts; collateral value is `Σ amount × price × (1 − haircut)` using the same adapters. Collateral is liquidated through Kuru when account health fails. Lets holders of tokenized stocks trade perps on other stocks without selling.

**Agent identity and reputation-based margin (Phase 3).** An operator registered in an ERC-8004 identity registry gets `agentFeeTierBps`. A reputation score built from realized PnL, liquidation history and market-creation record sets a margin tier: proven agents get initial margin down to 60% of standard, capped by account size. This is where the credit engine plugs into the trading venue.

**Creator-role secondary market (Phase 3).** Creator roles become transferable NFTs listed on Kuru; a market's fee stream can be bought and sold like a revenue share.

## Architecture

One contract per market, one vault for margin, and no storage slot that every trade writes. Monad executes transactions in parallel optimistically and serializes any two that touch the same slot, so global counters written per trade would collapse throughput to single-threaded speed.

| Contract | Role | Deployed as |
| --- | --- | --- |
| `MarginVault` | Holds USDC, per-user balances, operator (session key) policies | Singleton |
| `MarketFactory` | Deploys market clones, registers creator, collects seed bond | Singleton |
| `Market` | vAMM, positions, funding, OI, fee and insurance accumulators for one market | EIP-1167 clone per market |
| `IPriceSource` adapters | `PythAdapter`, `ChainlinkAdapter`, `NullAdapter` | One each, shared read-only |
| `Resolver` | Optimistic settlement for oracle-less markets | Singleton |
| `InsuranceBackstop` | Global backstop behind per-market insurance | Singleton, written only by sweeps and bad-debt claims |
| `FeeSweeper` | Batches protocol fee claims across markets | Singleton, called by keeper |

**Contention rules**

- A trade writes its `Market` clone's storage and the vault's user collateral, per-market ledger, and applicable operator/referral slots. The vault owns the authoritative ledger; no per-trade global aggregate is written.
- Protocol fees, insurance backstop and any leaderboard totals are read from per-market accumulators and swept in batches, never incremented on the trade path.
- No global nonces, no global position ids; position key is `(market, user)`.

**Trade path** (one transaction): caller → `Market.open` → read price (adapter, or Pyth payload carried in calldata) → settle funding on the position → compute fill on the vAMM with skew premium → check initial margin → `MarginVault.lock(user, margin)` → write position, OI, fee accumulators → emit `PositionOpened`.

## Data model

All amounts are 18-decimal fixed point internally (`WAD`); six-decimal USDC is scaled on vault entry and exit. In ledger invariants, `vaultCashWad = USDC.balanceOf(vault) × 10^12`, and signed accounts are summed with signed arithmetic. Prices are quote per base in WAD. Signed sizes: positive = long, negative = short.

```solidity
// Market clone storage (one per market)
enum Status { Active, Degraded, Paused, Settling, Settled }

struct MarketConfig {
    address priceSource;        // primary IPriceSource adapter; NullAdapter for oracle-less
    address secondarySource;    // optional fallback adapter, address(0) if none
    address creator;            // receives creatorShareBps of fees
    uint16  takerFeeBps;        // e.g. 8
    uint16  creatorShareBps;    // e.g. 3000 (30%)
    uint16  insuranceShareBps;  // e.g. 3000
    uint16  referralShareBps;   // e.g. 1000, from the protocol share
    uint16  maxLeverageX;       // 20 oracle-fed, 3 oracle-less
    uint16  mmrBps;             // maintenance margin ratio; oracle-less value also used while Degraded
    uint16  liqPenaltyBps;      // e.g. 150
    uint16  receiveCapX;        // funding receipt cap, default 10
    uint16  sideCapBps;         // floor(10_000 × φ(λ)); applied cap uses this rounded-down value
    uint16  impactMarginBps;    // scales the impact minimum of initial margin, default 10000
    uint32  maxOracleAgeBlocks; // opens only, default 10
    uint32  degradeAfterBlocks; // default 100
    uint32  degradedTwapBlocks; // default 600
    uint64  fundingCapPerBlock; // WAD-scaled cap on |f| per block
    uint64  skewCoeff;          // WAD-scaled c for the Phase 2 skew premium; 0 at launch
    Status  status;
    uint64  statusSince;        // block of last status change
}

struct AmmState {
    uint256 baseReserve;        // virtual B
    uint256 quoteReserve;       // virtual Q
    uint256 k;                  // B * Q at seed, updated on reseed only
    uint256 baseAtSeed;         // B0, for side caps and worstExit
    uint256 curveBase;          // Q0; reset to the new quote reserve on a zero-OI reseed
    int256  entryCostNet;       // E: sum of open long entry costs minus open short entry proceeds
}

struct FundingState {
    int256  longIndex;          // WAD quote per base; rises when longs pay
    int256  shortIndex;
    int256  longWeighted;       // Σ |size| × lastFundingIndex over open longs, WAD²
    int256  shortWeighted;      // same sum over open shorts, WAD²
    uint256 remainderHi;       // accumulated accrual remainders, WAD²
    uint256 roundingHi;        // Σ (owed × WAD − dHi) over funding settlements, WAD²
    uint256 sweptHi;           // total funding surplus swept to insurance × WAD
    uint64  lastBlock;
}

struct OpenInterest {
    uint256 longSize;           // base units, for funding
    uint256 shortSize;
    uint256 longNotional;       // quote, for caps and fees
    uint256 shortNotional;
    uint256 oiCap;              // min(insurance bound, depth bound)
}

struct Position {
    int256  size;               // base units, signed; positive = long
    uint256 margin;             // quote, locked in vault
    uint256 entryCost;          // exact quote paid (long) or received (short) at open; reduced pro-rata on partial close
    int256  lastFundingIndex;   // snapshot of the index for this position's side
}

struct Ledger {
    uint256 protocolOwed;
    uint256 creatorOwed;
    uint256 insurance;          // this market's sub-fund
    int256  clearing;           // see Solvency and the vault ledger
    int256  fundingPool;        // funding cash in transit between payers and receivers; sign free; see Funding
    uint256 skewPool;           // Phase 2 impact pool; 0 at launch
}

mapping(address => Position) positions;
// ring buffer of (block, mark) samples for the TWAPs
```

```solidity
// MarginVault storage: every unit of USDC belongs to exactly one of these accounts
mapping(address user => uint256) free;
mapping(address user => mapping(address market => int256)) locked; // signed collateral; negative means isolated debt
mapping(address market => int256)  clearing;      // signed; mirrors Ledger.clearing, held here for the cash invariant
mapping(address market => uint256) insurance;
mapping(address market => int256)  fundingPool;      // signed, see Funding
mapping(address market => uint256) skewPool;         // Phase 2
uint256 backstop;
mapping(address market => uint256) protocolOwed;
mapping(address market => uint256) creatorOwed;
mapping(address referrer => uint256) referralOwed;
mapping(address => bool) isMarket;                // set by factory

// referrals
mapping(bytes32 code => address owner) referralCodeOwner;
mapping(address user => address referrer) referrerOf;

struct OperatorPolicy {
    uint64  expiry;           // exclusive block number; block.number >= expiry rejects
    uint128 maxNotionalPerTx;
    uint128 maxTotalNotional;
    uint128 usedNotional;
    bytes32 marketsRoot;      // merkle root of allowed markets, or 0 = any
    bool    canClose;
}
mapping(address user => mapping(address operator => OperatorPolicy)) operators;
```

**Invariants to hold in tests**

- Cash equality: `vaultCashWad == Σ free + Σ locked + Σ clearing + Σ insurance + backstop + Σ owed + Σ skewPool + Σ fundingPool`, at every block.
- Exact conservation per market: `clearing == (Q − curveBase) − entryCostNet`, at every block, with integer arithmetic; fees, funding and skew premiums are outside it.
- Entry cost consistency: `entryCostNet == Σ entryCost over open longs − Σ entryCost over open shorts`, and every `entryCost` equals the curve fill it was opened at, reduced pro-rata on partial close with the rounding dust pushed into `entryCostNet` explicitly.
- Solvency per market: for every open position, realizable loss at current reserves `≤ margin`; when violated for any position, that position is liquidatable and bad debt, if any, is recorded and emitted in the liquidating transaction.
- Impact margin: immediately after any open, the new position's worst-case loss at the reserves the side caps allow (long: `entryCost − worstExit`; short: `worstBuyback − P`) is `≤ margin − notional × mmr`.
- Side cap: both `longSize` and `shortSize` are at most `floor(sideCapBps × baseAtSeed / 10_000)` after any open.
- Funding, per accrual interval: `perUnit × payN − perRecv × recvN ≥ 0`, and no accrual while either side is empty.
- Funding, at every block: with `pendingHi = (longIndex × longSize − longWeighted) + (shortIndex × shortSize − shortWeighted)`, `surplusHi = fundingPool × WAD + pendingHi == int(remainderHi) + int(roundingHi) − int(sweptHi) ≥ 0`. Cast before subtraction: a sweep can include rounding surplus, so `sweptHi` can exceed `remainderHi`. `fundingPool` and `pendingHi` may each have either sign.
- Settlement rounding: each funding settlement contributes `0 ≤ owed × WAD − dHi < WAD` to `roundingHi`; therefore `0 ≤ roundingHi ≤ WAD × settlementCount`, where `settlementCount` is a test-only counter. The bound is per settlement, not per position or per accrual interval.
- Weighted-sum consistency: `longWeighted == Σ over open longs of |size| × lastFundingIndex`, and likewise for shorts.
- `longSize − shortSize == baseAtSeed − baseReserve` (the curve's net position equals the book's net position).
- Insurance accounting includes the seed bond: `insurance == initialInsurance + seedTopUps + insuranceFeeShare + insurancePenaltyShare + fundingSurplusSweeps + otherInsuranceCredits − badDebtDebits − outboundInsuranceSweeps − bondRefunds`. Every credit and debit has a matching ledger entry; protocol, creator and referral claims are tracked separately.
- A position with `size == 0` has `margin == 0`, `entryCost == 0` and no snapshot.
- No open in `Degraded`, `Paused`, `Settling` or `Settled`; closes succeed in `Active` and `Degraded` without any oracle read.
- Reseed only when `longSize == shortSize == 0`; afterwards `clearing == 0`, `entryCostNet == 0`, `Q == curveBase`, `B == baseAtSeed`.

## Pricing

Fills come from a constant-product virtual AMM plus a skew premium that charges the crowded side. There is no real liquidity behind the curve; it only sets price impact.

**Seeding.** The creator supplies an initial price `p0` and a depth `L` in quote terms (bonded, see Factory). Reserves are set so a trade of notional `x` moves price by roughly `x / L`:

```latex
Q_0 = L, \qquad B_0 = \frac{L}{p_0}, \qquad k = B_0 \cdot Q_0
```

**Mark price** is the instantaneous curve price, `mark = Q / B`.

**Fill for a long of base size `s`** (buying base from the curve):

```latex
Q' = \frac{k}{B - s}, \qquad \text{cost} = Q' - Q, \qquad \text{avg fill} = \frac{Q' - Q}{s}
```

A short is the mirror: `B' = B + s`, `Q' = k / B'`, proceeds `Q − Q'`. Trades that would drive `B − s ≤ 0` revert.

**Skew premium: Phase 2, disabled at launch (`skewCoeff = 0`).** A price tilt charged on top of the curve fill is cash the curve never receives, so it cannot live inside `entryCost` without breaking the clearing identity (Solvency and the vault ledger): reserves would move by the fill while `E` moved by the tilted cost. When enabled it is accounted like an impact pool. A trade that increases `|skew|` pays `premium = fill × c × |skew_after|` from the trader's free balance into `skewPool[market]`; a trade that reduces `|skew|` receives a rebate of the same form, paid from `skewPool` and capped at its balance, so the pool never goes negative; `entryCost` and `E` record the curve fill only; `skewPool` is a ledger account in the cash identity and its balance above a floor sweeps to insurance monthly. `c` defaults to 2% oracle-fed and 5% oracle-less when enabled, and the worst-case premium on close enters `worstExit` as a factor `(1 − c)`. Until then, skew is handled by skew funding (Funding), the fee discount for skew-reducing trades (Growth mechanics) and impact-aware initial margin (Margin and liquidation).

**Oracle-fed markets** use the adapter price as the funding index and as the reference for liquidation health. The vAMM mark drifts from the index only through trade flow and is pulled back by funding.

**Oracle-less markets** have no external index. Liquidation health uses a 300-block TWAP of mark (about 90 seconds), computed from a ring buffer of `(block, mark)` samples written on each trade. Funding runs on skew alone.

**Reseeding.** Allowed only while `longSize == shortSize == 0`, when `E = 0`, `Q = curveBase` and `clearing = 0`. Deepening a curve under open positions changes their realizable PnL: doubling the reserves after A's first trade in the worked example (Solvency and the vault ledger) turns A's realizable profit from 0 into 218.18 at the same mark, which is value created from nothing unless the reseeder pays it in; scaling `baseAtSeed` would also break the identity `longSize − shortSize == baseAtSeed − baseReserve`. Funded reseeds are a Phase 3 question. At zero OI the creator sets a new `L` at the current mark: `B0' = L / mark`, `Q0' = L`, `k' = B0' · Q0'`, `baseAtSeed = B0'`, `curveBase = Q0'`, and the side cap is recomputed from `B0'`. Shallowing is allowed under the same condition, subject to the depth minimum in Market factory.

## Funding

Funding accrues every block through two per-market cumulative indexes, one per side, updated lazily on every interaction. On a vAMM the two sides are not equal: the virtual pool is the counterparty, so a market can be 100 long and 60 short. A single signed index would then make longs pay more than shorts receive (or the reverse), and the vault would silently accumulate a surplus or a hole. Funding is instead zero-sum by construction: the paying side pays the rate per unit of size, the receiving side receives the payers' total pro-rata with receipts capped, and whatever the receivers are not owed stays in the market's funding pool and is swept to insurance. Nothing moves in the ledger at accrual; cash moves only when a position settles, so ordering of settlements is free and every rounding is explicit.

**State**

The authoritative `FundingState` is in Data model. Sizes are WAD base and indexes are WAD quote per base. Weighted sums, pending obligations, accrual remainders and settlement rounding are stored as WAD² products; they are not rounded to quote WAD on each accrual. `OpenInterest` supplies the two size totals, and `Ledger.fundingPool` records signed quote WAD transferred at settlement or sweep. `roundingHi` records actual settlement rounding separately from `remainderHi`.

The pseudocode below uses mathematical signed integers for ledger deltas. Solidity must use checked casts, full-precision multiplication/division and explicit bounds for stored WAD² products. In particular, multiplying an index by a size must not silently wrap, and an unsigned counter must be converted before participating in a signed subtraction.

**Accrual** is the first statement in every `open`, `close`, `liquidate` and `poke`, so open interest is constant across the interval it settles:

```solidity
function _accrueFunding() internal {
    uint64 elapsed = uint64(block.number) - funding.lastBlock;
    if (elapsed == 0) return;
    funding.lastBlock = uint64(block.number);
    uint256 L = oi.longSize; uint256 S = oi.shortSize;
    if (L == 0 || S == 0) return;                                 // no counterparty, no funding
    int256 f = _fundingRatePerBlock();                            // WAD fraction of price per block, signed, clamped
    if (f == 0) return;
    uint256 absF    = uint256(f > 0 ? f : -f);
    uint256 perUnit = absF * _refPrice() / WAD * elapsed;         // quote per WAD base owed by each payer unit
    (uint256 payN, uint256 recvN) = f > 0 ? (L, S) : (S, L);
    uint256 perRecv = perUnit * payN / recvN;                     // pro-rata receipt per unit, floored
    uint256 capRecv = perUnit * config.receiveCapX;               // default 10x the per-unit payment
    if (perRecv > capRecv) perRecv = capRecv;
    funding.remainderHi += perUnit * payN - perRecv * recvN;      // >= 0 by construction; NO ledger move here
    if (f > 0) { funding.longIndex  += int256(perUnit); funding.shortIndex -= int256(perRecv); }
    else       { funding.shortIndex += int256(perUnit); funding.longIndex  -= int256(perRecv); }
    emit FundingAccrued(address(this), f, funding.longIndex, funding.shortIndex, uint64(block.number));
}

// Settlement, on every touch of a position (open, close, addMargin, removeMargin, liquidate), before any size change:
//   idx  = position.size > 0 ? funding.longIndex : funding.shortIndex
//   dHi  = |size| × (idx − position.lastFundingIndex)              // WAD², signed; positive = the position pays
//   owed = dHi > 0 ? ceilDiv(dHi, WAD) : −(|dHi| / WAD)            // payers round up, receivers round down
//   locked[user][market] −= owed;   ledger.fundingPool += owed;
//   funding.roundingHi += uint256(owed × WAD − dHi);              // in [0, WAD), including when owed is negative
//   weighted_side += dHi;           position.lastFundingIndex = idx;
// After a size change of Δ in |size| (positive on open, negative on close or liquidation):
//   weighted_side += Δ × idx;       sizeSum_side += Δ;

// Pending funding still owed by (positive) or to (negative) open positions, exact, WAD²:
//   pendingHi = (longIndex × longSize − longWeighted) + (shortIndex × shortSize − shortWeighted)

// Sweep, anyone may call; keeper runs it monthly:
//   surplusHi = fundingPool × WAD + pendingHi;    // signed; accrued surplus after reserving pending receiver obligations
//   assert(surplusHi == int(remainderHi) + int(roundingHi) − int(sweptHi) && surplusHi >= 0);
//   amount    = uint256(surplusHi) / WAD;         // quote WAD; floor once here, retain any fractional remainder
//   ledger.insurance += amount;  ledger.fundingPool −= amount;  funding.sweptHi += amount × WAD;
//   emit FundingSurplusSwept(address(this), amount);
```

Before a position changes side, settle and remove its old side's weighted contribution, then initialize the new side's snapshot at that side's current index. A new position owes no funding from before it opened. Partial closes remove only the closed size's weighted contribution after settling the whole position. A full close removes the contribution and clears the snapshot. These rules keep `pendingHi` equal to the exact sum of open positions' remaining funding obligations under arbitrary changes of size.

`_refPrice()` is the index for oracle-fed markets and the mark TWAP for oracle-less markets. Receiver-index division dust and the receipt-cap excess accumulate in `remainderHi`; settlement rounding accumulates in `roundingHi`. Neither accumulator directly credits insurance. Insurance receives only the amount computed by the surplus sweep, and repeated sweeps without intervening accrual or settlement cannot pay twice. The surplus can include uncollected payer obligations; it is an accounting surplus, not a claim that `fundingPool` already contains positive cash.

**Rate, oracle-fed markets.** Premium of mark over index, spread over a funding period `F` of 12,000 blocks (about one hour), clamped:

```latex
f = \text{clamp}\left( \frac{\text{mark} - \text{index}}{\text{index} \cdot F},\; -f_{max},\; f_{max} \right)
```

**Rate, oracle-less markets.** No index exists, so imbalance is the only signal. The heavier side pays in proportion to skew:

```latex
f = \text{clamp}\left( \frac{c_f \cdot (OI_{long} - OI_{short})}{(OI_{long} + OI_{short}) \cdot F},\; -f_{max},\; f_{max} \right)
```

with `c_f` defaulting to 0.05 per period. In `Degraded` state (Oracle adapters) the rate is forced to zero.

**Settlement on a position.** A position snapshots the index of its own side at every touch. Let `dHi = |size| × (sideIndex − position.lastFundingIndex)`. Funding owed in quote WAD is the signed ceiling of `dHi / WAD`: positive means the position pays, negative means it receives. It is applied to margin on every interaction, then the snapshot is refreshed. Payers round up and receivers round down in absolute amount. A position whose equity becomes negative from funding alone becomes liquidatable, not auto-closed; unsigned stored margin must not be allowed to underflow.

**Why it is exact.** An accrual increases both `pendingHi` and `remainderHi` by `perUnit × payN − perRecv × recvN`, with no ledger transfer. A settlement decreases `pendingHi` by `dHi` and increases `fundingPool × WAD` by `owed × WAD`; the difference is exactly the amount added to `roundingHi`. A sweep decreases both the surplus and its backing expression by `amount × WAD`. Therefore `fundingPool × WAD + pendingHi == int(remainderHi) + int(roundingHi) − int(sweptHi)` after every operation, including a rate reversal, partial close or change of side. Each settlement adds less than one quote wei of rounding; no per-position bound is assumed across repeated settlements.

For an uncapped 10-USDC payment and receipt with no rounding, payer-first settlement makes `fundingPool = +10` and `pendingHi / WAD = −10`; receiver-first settlement makes them `−10` and `+10`. The surplus is zero in either order, so neither state permits an insurance sweep. After both settle, both accounts are zero. Capped funding and rounding can leave a positive surplus; the sweep reserves pending receiver obligations through `pendingHi` before computing the amount.

**Regression vectors.** Quote wei below means one unit of the 18-decimal internal quote balance, not one six-decimal USDC unit.

| Case | Inputs | Required result |
| --- | --- | --- |
| Receipt cap | Per-unit payment 0.001 quote, payer size 100, receiver size 1, receive cap 10× | Payers owe 0.10 quote, receiver is owed 0.01, surplus is 0.09; no WAD² amount is added directly to an insurance balance |
| Uncapped division | Per-unit payment 1 quote, payer size 1, receiver size 3 | Receiver index is `floor(WAD / 3)`; the interval remainder is one quote wei, carried in `remainderHi` until swept |
| Repeated fractional accrual | Ten accruals of `perUnit = 10^15 + 1`, payer size `WAD / 2`, receiver size `WAD` | Payer settles `5,000,000,000,000,005` quote wei; receiver settles `5,000,000,000,000,000`; the five-wei surplus is entirely accrual remainder, with zero settlement rounding |
| Settlement order and sweep | Equal 10-USDC payer and receiver obligations | Both settlement orders preserve cash equality; a sweep between them transfers zero |

**Poke.** `poke()` is public and only accrues funding, refreshes the TWAP sample and evaluates the `Degraded` transition. Keepers call it on idle markets so the indexes never lag more than a few hundred blocks; agents can call it before reading `liquidationPrice`.

## Margin and liquidation

Margin is isolated per position for this build. Cross-margin ships in Phase 2 as a vault-level change (see Product phases) and does not touch the market contract.

**Initial margin** on open is the larger of the leverage minimum and the impact minimum:

```latex
m_{long} = \max\left( \frac{E}{\lambda},\; E - \text{worstExit}(s) + E \cdot \text{mmr} \right)
\qquad
m_{short} = \max\left( \frac{P}{\lambda},\; \text{worstBuyback}(s) - P + P \cdot \text{mmr} \right)
```

Here `E` is a long's curve entry cost and `P` is a short's curve entry proceeds. These formulas use the launch value `impactMarginBps = 10_000`. `worstExit(s)` is the position's close-alone value at the worst reserves the side caps allow, with the position itself still open. `C = floor(sideCapBps × B0 / 10_000)` is the per-side cap in base units; basis points must be divided by 10,000.

- Long of size `s`, entry cost `entryCost`: every short at cap and no other long, so reserves are `B0 + C − s` before the close and `B0 + C` after. `worstExit = k/(B0 + C − s) − k/(B0 + C)`; impact term `entryCost − worstExit + entryCost × mmr`.
- Short of size `s`, entry proceeds `P`: every long at cap and no other short, so reserves are `B0 − C + s` before the buy-back and `B0 − C` after. `worstBuyback = k/(B0 − C) − k/(B0 − C + s)`; impact term `worstBuyback − P + P × mmr`. The loss is buy-back cost minus proceeds, not the reverse.

A position posts the larger of its leverage minimum and impact minimum; which one binds depends on its entry cost, side, size and maintenance buffer. `impactMarginBps` (default 10,000, the full impact minimum) scales the impact term; governance can relax it once insurance is deep. Fees are charged on top and are not counted toward margin. `maxOpenable(user, isLong)` reports the largest size whose required margin fits the user's available balance and all applicable caps.

**The side cap is derived from leverage.** The continuous design value is:

```latex
\varphi(\lambda) = \frac{1 - r}{1 + r}, \qquad r = \sqrt{1 - 1/\lambda}
```

The stored parameter is `sideCapBps = floor(10_000 × φ(λ))`, and `C = floor(sideCapBps × B0 / 10_000)`. Applied caps are 128 bps at 20x, 557 bps at 5x, 1,010 bps at 3x and 1,715 bps at 2x. Initial-margin checks use this same applied cap and the side-specific loss formulas above; the geometric cap does not replace the impact or maintenance-margin checks. Against seed `B0 = 100`, `Q0 = 10,000` (`k = 10^6`), a one-unit short at 5x has proceeds 99.01; with `C = 5.57`, its worst buy-back is approximately 110.97, a loss of 11.96, so it posts the leverage minimum of 19.80. Under an arbitrary 25% cap the same short faced a reachable loss of 76.43. Depth is separate from the bond (Market factory): the bond sets insurance, while depth must support the intended quote OI bound after applying the rounded cap and the seed price.

**Health** (view, recomputed on every interaction, after funding accrual):

```latex
\text{health} = \frac{\text{margin} + \text{pnl}_{ref} - \text{fundingOwed}}{\text{entryCost}}
```

`pnl_ref` is the realizable PnL defined in Solvency and the vault ledger, evaluated at the reserves implied by the mark TWAP (300 blocks in `Active`, 600 in `Degraded`). For oracle-fed markets `pnl_ref = min(realizable, indexPnL)` where `indexPnL = size × index − entryCost` for a long and `entryProceeds − |size| × index` for a short; for oracle-less and `Degraded` markets it is realizable alone. Valuation at spot mark is never used for health. Liquidations execute at actual reserves, so exit impact lands on the liquidated trader.

**Liquidatable** when `health < mmrBps / 10_000`. Defaults: 2.5% for oracle-fed (20x), 15% for oracle-less (3x).

**Liquidation flow** (`liquidate(user)`, anyone may call):

1. Accrue funding, settle it on the position.
2. If `|size| × p_ref > partialThreshold` (default 50,000 USDC notional), close 50% of size; otherwise close 100%.
3. Close through the vAMM at the actual fill (this is where the exit impact lands, on the liquidated trader).
4. Penalty `liqPenaltyBps` of closed notional: 40% to the caller, 60% to the market insurance sub-fund.
5. Remaining margin, if positive, stays in the position (partial) or returns to the vault (full).

**Bad-debt waterfall** when margin after close is negative:

1. Market insurance sub-fund covers the shortfall.
2. `InsuranceBackstop` (global) covers the remainder, capped per market per day at `backstopDailyCap`.
3. Auto-deleverage: the most profitable positions on the opposite side are force-closed at `p_ref`, largest PnL-to-margin ratio first, until the shortfall is covered. ADL emits an event per affected position.

**OI caps** constrain each side in two units: quote notional must not exceed `(insuranceBalance + backstopAllocation) × oiMultiplier`, and base size must not exceed `C = floor(sideCapBps × B0 / 10_000)`. The quote notional of each side uses the current mark, including the post-trade mark when validating an open. Apply both checks independently; do not compare a quote amount directly with a base size. Launch notional caps apply in addition. The factory's depth minimum supports the initial insurance bound at the seed price; later price changes can change which bound binds. Opens that breach either bound revert; closes and liquidations remain available.

**Agent-facing views**: `health(user)`, `liquidationPrice(user)`, `maxOpenable(user, isLong)`, `quoteOpen(size)`, `quoteClose(user, sizeFraction)`. All are exact, not estimates; the SDK calls them before every send.

## Solvency and the vault ledger

Winners are paid before losers close, so the vault names that gap explicitly instead of hiding it inside a balance. Three quantities must never be confused: cash (what the ledger holds), curve state (what the vAMM reserves imply), and valuation (what a position looks like at a mark nobody has traded at). Invariants use only the first two. Valuation is for display and, in its conservative form below, for health.

| Account | Scope | Moves on |
| --- | --- | --- |
| `free[user]` | per user | deposit, withdraw, close, claims, skew premium and rebate (Phase 2) |
| `locked[user][market]` | per position | open, addMargin, removeMargin, close, liquidate, funding settlement |
| `clearing[market]` (signed) | per market | every close and liquidation: minus realized profit paid out, plus realized loss taken in |
| `insurance[market]` | per market | fee share, liquidation penalties, funding sweeps, bad debt |
| `fundingPool[market]` (signed) | per market | plus each payer's settled funding, minus each receiver's; minus sweeps to insurance; may be negative while receivers have settled ahead of payers |
| `skewPool[market]` (Phase 2) | per market | premiums in, rebates out, surplus sweep to insurance |
| `backstop` | global | surplus sweeps in, bad debt out |
| `protocolOwed[market]`, `creatorOwed[market]`, `referralOwed[referrer]` | per market or referrer | fee accrual, claims |

**Cash invariant**, preserved by every balanced settlement: `vaultCashWad == Σ free + Σ locked + Σ clearing + Σ insurance + backstop + Σ owed + Σ skewPool + Σ fundingPool`, with `vaultCashWad = USDC.balanceOf(vault) × 10^12`. Every term uses quote WAD, and the sum uses signed arithmetic. `locked` may be negative when settled funding exceeds position collateral; `fundingPool` may be negative when receivers settle first or accrued surplus is swept before payers settle. Each settlement applies explicit counter-entries; invariant handlers and read-only watchers recompute the full equality without a global sum on the trade path. Direct token donations create separately observable, unallocated excess cash outside these protocol transitions. This is a double-entry identity; it catches accounting bugs, not economic ones. The economic invariants follow.

**Curve accounting.** Each market stores two more integers: `curveBase` (`Q0`, the quote reserve at seed, reset to the new quote reserve only on a zero-OI reseed) and `entryCostNet` (`E`, the sum over open positions of entry cost for longs minus entry proceeds for shorts, in quote). Each position stores `entryCost`, the exact quote it paid or received at open, reduced pro-rata on partial close, instead of an entry price, so `E` is a sum of exact integers.

**Exact conservation**, at every block:

```latex
\text{clearing} = (Q - Q_0) - E
```

`Q − Q0` is the net quote traders have paid into the curve over every trade ever made. `E` is the part attributable to positions still open. What remains is closed round-trips, whose net inflow is minus the realized PnL paid out, which is `clearing` by definition. Fees sit outside it. Corollary: the aggregate PnL that the open positions will realize on a full unwind is exactly `clearing`, so lifetime realized PnL on a market sums to zero, and a market that returns to `Q = Q0` with no open positions has `clearing = 0`.

**Realizable versus valuation.** The close-alone value of a long of size `s` at reserves `(B, Q)` is `Q − k/(B + s)`; the buy-back cost of a short of size `s` is `k/(B − s) − Q`. Realizable PnL is that minus (or entry proceeds minus that). Valuation, `size × mark − entryCost`, overstates whenever the mark moved because of the position's own trade: a lone long shows positive valuation and zero realizable PnL. Health therefore uses realizable PnL, evaluated at the reserves implied by the mark TWAP (`B = √(k / twap)`, `Q = √(k · twap)`, since `k` is constant) so a single-block push cannot liquidate anyone, and for oracle-fed markets takes the worse of realizable and index-valued PnL so a position cannot hide behind a curve the index disagrees with. Liquidation executes at actual reserves.

**Solvency condition.** No bad debt can arise from the curve while every open position's realizable loss is at most its margin. Impact-aware initial margin (Margin and liquidation) enforces that at open for the worst reserves the caps allow; health at realizable value enforces it thereafter; when it fails, bad debt is recognized at liquidation.

**Bad debt** is recognized at the moment a liquidation closes a position whose realized loss exceeds its margin. The shortfall is debited from `insurance[market]`, then `backstop` within its daily cap, then recovered by auto-deleveraging the most profitable open positions on the opposite side at their realizable value, in that order, and every step is emitted. Realized profit already in `free` is never clawed back; ADL touches open positions only.

**Payout rule.** A winner's close is never reverted for lack of vault solvency. The payout comes from pooled cash and any deficit follows the waterfall in the same transaction. Withdrawals draw on `free` only.

**Worked example, exact.** Seed `B0 = 120`, `Q0 = 12,000` (`p0 = 100`, `k = 1,440,000`), 5x leverage, fees and penalties omitted so the arithmetic is bare.

1. A buys 20: `B = 100`, `Q = 14,400`; A pays 2,400, margin 480. `E = 2,400`, `Q − Q0 = 2,400`, `clearing = 0`. Mark is 144. A's valuation is `20 × 144 − 2,400 = +480`; A's realizable value is `14,400 − 1,440,000/120 = 2,400`, PnL 0.
2. C buys 20: `B = 80`, `Q = 18,000`; C pays 3,600, margin 720. `E = 6,000`, `Q − Q0 = 6,000`, `clearing = 0`. Mark is 225. C's valuation is +900; C's realizable PnL is 0. A's realizable value is now `18,000 − 1,440,000/100 = 3,600`, PnL +1,200.
3. A closes: `B = 100`, `Q = 14,400`; A receives 3,600, profit 1,200; `free[A] += 480 + 1,200`; `clearing = −1,200`. `E = 3,600` (C only), `Q − Q0 = 2,400`, and `(Q − Q0) − E = −1,200 = clearing`. C's realizable value is now `14,400 − 1,440,000/120 = 2,400`, PnL −1,200, against 720 margin: health is negative, C is liquidatable. (C's valuation at mark 144 is −720, health exactly zero; realizable is 480 worse, which is the point.)
4. C is liquidated: `B = 120`, `Q = 12,000`; the close returns 2,400, loss 1,200; 720 comes from C's margin and 480 is bad debt paid by `insurance[market]`; `clearing += 1,200` back to 0; `E = 0`; `Q = Q0`. Lifetime realized PnL is `+1,200 − 1,200 = 0`. A's profit was funded by C's margin and the insurance fund.

C at 5x on a side that was a third of reserves was insolvent the moment A closed. The impact-aware initial margin would have required C to post at least 1,200 plus buffer, or refused the size.

## Oracle adapters

One interface, three adapters. The market never knows which oracle it is talking to; it only knows whether it has an external index at all.

```solidity
interface IPriceSource {
    /// @return price WAD quote-per-base; @return updatedBlock block the price is valid for;
    /// @return confBps half-width of confidence interval in bps; @return isExternal false for NullAdapter
    function getPrice(bytes32 feedId, bytes calldata update)
        external payable returns (uint256 price, uint64 updatedBlock, uint16 confBps, bool isExternal);
    function isSupported(bytes32 feedId) external view returns (bool);
}
```

**PythAdapter.** Pull model: the trader's transaction carries the signed price update in `update` and forwards the Pyth fee as `msg.value`. The adapter calls `updatePriceFeeds`, then reads `getPriceNoOlderThan(feedId, maxAge)`. If `update` is empty it reads the current on-chain price and lets the market's staleness check decide. This is how fills get sub-second freshness with no keeper in the loop.

**ChainlinkAdapter.** Push feeds: reads `latestRoundData`, converts `updatedAt` to a block estimate using 300 ms per block. Used where Pyth has no feed. Data Streams support is a follow-up.

**NullAdapter.** Returns `(0, block.number, 0, false)`. The market treats `isExternal == false` as oracle-less mode: funding on skew, health on mark TWAP, leverage cap 3x.

**Staleness and the Degraded state.** Opens require a fresh index: revert with `StaleOracle` if `block.number − updatedBlock > maxOracleAgeBlocks` (default 10, about 3 seconds) or if `confBps > 100`. Closes never require the index. A close is a trade on the curve and the curve does not need the oracle, so a trader can always exit, outage or not. Liquidations do need a reference price, so an outage cannot simply halt them; instead the market degrades rather than stopping:

- `Active → Degraded` when the primary adapter has been stale for more than `degradeAfterBlocks` (default 100, about 30 seconds) and no listed secondary adapter (a Chainlink push feed for the same asset) is fresh. Any interaction or `poke()` performs the transition and records the block.
- In `Degraded`: opens are paused; the funding rate is forced to zero; health uses a 600-block mark TWAP (about three minutes) with the oracle-less maintenance margin; liquidations are partial only (50% per call) and pay the standard penalty; closes work as normal; `addMargin` works as normal.
- `Degraded → Active` on the first fresh price with `confBps ≤ 100`: anyone calls `remark()`, the transition block is recorded, funding resumes, opens reopen, and each position is re-evaluated at the new index on its next touch or by a keeper sweep.
- `Degraded` for longer than `maxDegradedBlocks` (default 2 days) escalates to the Guardian, who can wind the market down through the Resolver at the mark TWAP.

**Equity feeds and market hours.** When the underlying market is closed, Pyth marks equity feeds stale, so an equity market enters `Degraded` at the bell with a known reason and exits at the first print. The Phase 2 market-hours engine (Product phases) is this state machine plus the pre-close margin ratchet and gap settlement on re-mark; it is not a separate mechanism.

**Feed allowlist.** The factory holds `allowedFeeds[adapter][feedId] = true`; anyone can add a feed by paying `feedListingBond`, refundable after 30 days if the feed is not slashed for misconfiguration. This keeps market creation permissionless without letting a creator point a market at a nonsense feed.

## Market factory and creation

Anyone creates a market in one transaction. The creator posts a seed bond that becomes the market's initial insurance sub-fund, which sets its OI cap. Depth `L` is a separate, virtual parameter that costs nothing and must be deep enough for that cap at the market's leverage. In return the creator earns `creatorShareBps` of every fee the market ever collects.

```solidity
struct CreateParams {
    string  symbol;           // "SPACEX-PERP", "NVDA-PERP"
    address priceSource;      // must be a registered adapter
    bytes32 feedId;           // 0 for NullAdapter
    uint256 initialPrice;     // WAD; ignored for oracle-fed (read from feed)
    uint256 depth;            // L in quote WAD; virtual; >= ceilDiv(oiMultiplier * seedBondWad * 10_000, sideCapBps)
    uint256 seedBond;         // USDC, >= minSeedBond for the market kind; becomes initial insurance and sets the OI cap
}

function createMarket(CreateParams calldata p) external returns (address market);
```

**Rules**

- `seedBond ≥ minSeedBond` for the market kind (default 2,000 USDC oracle-less, 5,000 USDC oracle-fed). The bond is the initial `insuranceBalance`, so the insurance bound on OI per side starts at `oiMultiplier × bond` (oiMultiplier is 20 oracle-fed, 10 oracle-less).
- `depth ≥ depthMin = ceilDiv(oiMultiplier × seedBondWad × 10_000, sideCapBps)`, where `seedBondWad` is the posted USDC bond scaled to 18 decimals. Use the applied integer cap from Margin and liquidation, not a rounded decimal approximation to `φ(λ)`. At 3x, a 2,000-USDC oracle-less bond and a 1,010-bps cap require approximately 198,019.802 USDC of virtual depth (198,020 if quoting whole USDC). At 20x, a 5,000-USDC oracle-fed bond and a 128-bps cap require 7,812,500. For comparison, the ideal continuous caps would give approximately 197,979.590 and 7,798,717.738 respectively. After deriving integer reserves, also verify that `floor(C × initialPrice / WAD)` covers the initial insurance bound; round depth upward further if reserve rounding requires it. Depth is virtual: deeper is always allowed and makes price move less per unit of flow.
- The bond is locked while the market has OI. When OI is zero and the creator calls `windDown`, the bond returns minus any bad debt it absorbed.
- Oracle-fed markets require `allowedFeeds[priceSource][feedId]`; the creator cannot override risk parameters. Oracle-less markets always get the oracle-less parameter set.
- One market per `(priceSource, feedId)` for oracle-fed; unlimited oracle-less markets, but `symbol` must be unique.
- The factory records `creator`, `createdBlock`, `symbol`, and emits `MarketCreated(market, creator, symbol, isExternal)`.

**Creator economics.** `creatorOwed` accrues per trade; `claimCreatorFees()` on the market transfers it out. The creator role is transferable (`transferCreator`) so market ownership can itself be sold. Agents can be creators; the agent that spots an S-1 filing and deploys the market first keeps the fee stream.

**Deployment.** `Clones.cloneDeterministic(marketImplementation, salt)` with `salt = keccak256(symbol)`, so a market's address is predictable before it exists. Initialization is a single `initialize(config, ammSeed)` guarded against re-entry and re-initialization.

## Resolver

Oracle-less markets settle through an in-house optimistic oracle: anyone proposes a settlement price with a bond, anyone can dispute it with a matching bond, and an unresolved dispute escalates to a council multisig for this build.

**States**: `Active → Proposed → (Disputed →) Settling → Settled`, or `Active → WindingDown → Settled`.

**Propose.** `propose(market, price, evidenceURI)` with `proposalBond` (default 2,000 USDC). Valid only if the market's creator has declared a settlement event (`declareSettlementEvent(kind, expectedBlock)`, kinds: `IPO_OPEN`, `ACQUISITION`, `SECONDARY_MARK`) or 30 days have passed since the last mark refresh. Opens are paused from the moment of proposal.

**Dispute window.** 24 hours (288,000 blocks). `dispute(market, counterPrice)` with an equal bond. No dispute: proposer's bond returns plus 10% of the disputer-less pool from insurance as a reward; market moves to `Settling`.

**Escalation.** A dispute goes to the 3-of-5 council, which picks one of the two proposed prices within 48 hours. Loser's bond is split 50% to the winner, 50% to the market insurance sub-fund. Council membership is a `Resolver` parameter; replacing it with a token vote or a third-party optimistic oracle is a later upgrade.

**Settling.** All positions close at the settlement price, longs first by descending size, then shorts. PnL is paid from counter-side margin plus the insurance sub-fund plus the backstop. If those are insufficient, the shortfall is socialized pro-rata across profitable positions and emitted as `SettlementHaircut(bps)`. Margin returns to the vault; the market flips to `Settled` and rejects everything except `withdraw`.

**Wind-down** (company never IPOs, market goes stale). When OI is zero the creator can `windDown` immediately. When OI is nonzero and no trade has occurred for 90 days, anyone can start a wind-down: opens pause, funding rate is set to push both sides to close, and after 14 more days positions settle at the 300-block mark TWAP. This is the answer to "what if it never lists": the market decays to closure rather than living forever.

**Rolling secondary marks.** Between events, a market can refresh its reference through the same propose/dispute flow with `SECONDARY_MARK`; the accepted price only updates the TWAP anchor used for health, it does not settle positions.

## Fees

Every fee is accrued into one of three per-market accumulators on the trade path and moved out later by claims and sweeps. Nothing on the trade path writes to a treasury or a global total.

| Fee | Charged on | Default | Split |
| --- | --- | --- | --- |
| Taker fee | Open and close notional | 8 bps | 30% protocol, 30% creator, 30% market insurance, 10% referrer (protocol keeps the 10% when there is no referrer) |
| Skew-reducing discount | Opens that shrink absolute skew | `takerFee × (1 − 0.5 × abs(skew_before))` | Apply the normal taker-fee split to the discounted fee |
| Liquidation penalty | Liquidated notional | 150 bps | 40% liquidator, 60% market insurance |
| Settlement fee | Notional at oracle-less settlement | 50 bps | 50% protocol, 50% market insurance |
| Insurance surplus sweep | Market sub-fund above `3 × oiCap / oiMultiplier` | Monthly | 50% backstop, 50% protocol treasury |
| Market creation | Seed bond | Minimum 5,000 USDC oracle-fed / 2,000 USDC oracle-less | Becomes market insurance; refundable net of absorbed losses on clean wind-down; depth is separate |
| Feed listing | Adding a feed to the allowlist | 500 USDC | Refundable after 30 days |

**Claims and sweeps**

- `claimCreatorFees()` on a market: only the creator, transfers `creatorOwed` from the vault to the creator.
- `FeeSweeper.sweep(address[] markets)`: anyone may call; moves each market's `protocolOwed` to the treasury in one transaction. Keeper runs it hourly. This is the only place the treasury balance changes.
- `InsuranceBackstop.topUp(market)`: moves any market insurance sub-fund above `2 × oiCap / oiMultiplier` into the global backstop, so healthy markets fund the backstop that protects new ones.

**Funding is not a trading fee.** It flows between traders through the side indexes. Receipt-cap excess, receiver-index division remainder and settlement rounding accrue as funding surplus and are swept to that market's insurance through the Funding rules. No funding surplus is credited directly to protocol or creator fees.

**Agent API metering** (off-chain, x402): quote and state endpoints are free on the public RPC path and paid on the hosted low-latency path. Not part of the contracts.

## Revenue model

The protocol earns 30 to 40 bps of every 100 bps of taker fees, plus settlement fees, insurance surplus and metered agent infrastructure. Everything else is paid out to the people who bring the volume.

| Line | Mechanism | Phase 1 (0.5M USDC/day) | Phase 2 (5M/day) | Phase 3 (25M/day) |
| --- | --- | --- | --- | --- |
| Taker fees, protocol share | 8 bps × volume × 30–40% | 44–58K USDC/yr | 0.44–0.58M | 2.2–2.9M |
| Settlement fees | 50 bps × settled notional × 50% | negligible | 50–150K | 0.5–1M |
| Insurance surplus | 50% of monthly sweep above cap | 0 | 50–200K | 0.5–1.5M |
| Agent API metering | x402 on hosted low-latency path | 0 | 20–100K | 0.3–1M |
| Creator-role marketplace | 2% of secondary sales | 0 | 0 | 0.1–0.5M |
| Total protocol revenue |  | \~50K | \~0.6–1.0M | \~3.6–6.9M |

Volume assumptions are targets, not forecasts. For calibration, all of Monad's perps volume is around 21M USDC/day today, so the Phase 3 target means owning most of the chain's leverage flow or growing it.

**Cost side**: keepers and relayer gas (recovered from penalties and markups), indexer and RPC hosting, Pyth update fees (paid by traders), external review (one-off), and MON incentives for points seasons (co-funded with the Foundation where possible).

**What the money is for**: insurance backstop first (target: 30 days of worst-case bad debt before Phase 3), then review and bug bounty, then incentives.

## Growth mechanics

Growth is built into the fee split and the share unit, not bolted on as a campaign. Two mechanics live in the contracts and must ship in Phase 1; the rest are off-chain but depend on events the contracts already emit.

**In the contracts (Phase 1)**

- Referrals. `MarginVault.registerReferralCode(bytes32 code)` claims a code; `MarginVault.setReferrer(bytes32 code)` binds a user once, permanently, before or after first deposit. On every fee accrual the market reads `vault.referrerOf(user)` and credits 10% of the taker fee to `referralOwed[referrer]` in the vault — a per-referrer slot, so no contention. Self-referral is blocked by address; wash referral is handled off-chain in points, not in the contract.
- Skew-reducing discount. An open that shrinks `|skew|` pays `takerFee × (1 − 0.5 × |skew_before|)`. This is the marketing line "get paid to take the other side" and it is also the cheapest risk control in the protocol.
- Creator earnings are a public view (`creatorOwed` plus lifetime claimed via the indexer), and the creator role is transferable. A market is an asset someone owns and promotes.

**The share unit.** Every market has a public page at pripo.fun`/m/<symbol>` with a live mark, OI, funding, and a creator-earnings counter, rendered into an OG image so the link previews with numbers. A market link is the thing people post.

**Agents as distribution**

- Launch agent: watches S-1 filings, large funding rounds and acquisition news; creates the pre-IPO market and posts the market link to X with the reasoning. Runs from Phase 1 in demo form, hardened in Phase 2.
- Nad.fun graduation agent (Phase 2): every token that graduates gets a perp within a block and a post in that token's community. Drops the protocol into every memecoin community on the chain the moment they have something to leverage.
- Every agent framework that adds the MCP server brings its users' volume; publish the server in the MCP registries and ship an example-agents repo.

**Points and competitions (Phase 2, designed now so events suffice)**

- Points season 1: volume, OI-days, markets created with OI, referred volume. Rewards in MON, co-funded with the Foundation where possible. Anti-wash: points net of same-funder wallets, self-referral, and round-trip trades inside 10 blocks, all computed in the indexer from existing events.
- Per-market competitions: a creator can sponsor a weekly volume competition from their own accrued fees (`sponsorCompetition(amount)` moves `creatorOwed` into a prize escrow paid by the indexer's leaderboard). Creators recruit for you.

**Retention**

- Telegram and Discord bot: liquidation warnings at 1.5× maintenance, new-market alerts by watchlist, settlement proposals on markets you hold.
- Portfolio page shows funding earned and referral earnings alongside PnL, so the account has more than one reason to be opened.

**Developer distribution.** SDK docs, a "trading agent in ten minutes" guide, an MCP quickstart, and the keeper as an open repo with a revenue calculator. Keepers and agents are users who bring volume and infrastructure at once.

**Metrics that matter** (indexer dashboards from day one): deposit-to-first-trade conversion, day-7 and day-30 trader retention, markets created per week and share with OI after 7 days, share of volume from operator keys, share of new depositors with a referrer, insurance balance versus OI cap per market.

## Vault, session keys and agent access

One USDC deposit into `MarginVault` funds trading on every market. Agents trade through operator keys with a scoped policy: they can open and close within limits but never withdraw.

**Vault surface**

```solidity
function deposit(uint256 usdc) external;
function withdraw(uint256 usdc) external;                 // only free balance; only the user
function lock(address user, uint256 amt) external;        // only registered markets
function release(address user, uint256 amt) external;     // only registered markets
function settlePnl(address user, int256 pnl) external;     // locked += pnl; clearing -= pnl
function settleFunding(address user, int256 owed) external; // locked -= owed; fundingPool += owed
function chargeFee(address user, FeeBreakdown calldata fee, bool fromLocked) external; // balanced debit and splits
function setOperator(address op, OperatorPolicy calldata policy) external;
function revokeOperator(address op) external;
function checkAndConsume(address user, address op, uint256 notional, bool isClose, bytes32[] calldata marketProof) external; // calling market supplies scope

// referrals (Phase 1)
function registerReferralCode(bytes32 code) external;     // one code per address, first come
function setReferrer(bytes32 code) external;              // binds once, permanent, not self
function referrerOf(address user) external view returns (address);
// chargeFee credits referralOwed only as part of a balanced fee debit
function claimReferral() external;

// phase 2 surface, reserved in the ABI now
function enableCrossMargin(bool on) external;
function accountHealth(address user) external view returns (int256);
```

Vault writes are scoped to the affected user, operator, market ledger and referrer. There is no unrestricted generic settlement credit; PnL, funding and fees each name their counter-account.

**Operator flow.** A user registers an agent's key once with `setOperator`. The agent then calls `market.openFor(user, size, maxPrice, oracleUpdate)`; the market calls `vault.checkAndConsume`, which verifies the caller is the registered operator, the policy has not expired, the market is in `marketsRoot` (or root is zero), `notional ≤ maxNotionalPerTx`, and `usedNotional + notional ≤ maxTotalNotional`. Any failure reverts before state changes.

The proof-carrying `openFor` and `closeFor` overloads append `bytes32[] marketProof`; the four-argument overloads use an empty proof. Leaves are `keccak256(bytes.concat(keccak256(abi.encode(market))))` in a sorted-pair Merkle tree. Both opens and closes consume actual curve quote notional, and closes additionally require `canClose`. `expiry` is an exclusive block number; replacing a policy resets `usedNotional` to zero.

**What the policy cannot grant**: withdrawals, operator changes, market creation on the user's behalf, or closing positions when `canClose` is false. A user can revoke at any time; open positions stay open and can be closed by the user.

**Gas sponsorship.** Operators pay their own gas. A relayer path (`openBySig` with an EIP-712 order signed by the operator key) ships in Phase 2 (see Product phases) so a hosted service can pay gas for agents.

**Agent identity (roadmap).** When an operator address is registered in an ERC-8004 identity registry, the market applies `agentFeeTierBps` instead of the default taker fee. Phase 3; see Product phases.

## Contract interfaces

Freeze these first; the SDK, MCP server, indexer and front end are all generated from them. Every mutating call has an exact view twin so agents can `eth_call` before sending.

```solidity
interface IMarket {
    // --- trading ---
    function open(int256 size, uint256 limitPrice, bytes calldata oracleUpdate) external payable;
    function openFor(address user, int256 size, uint256 limitPrice, bytes calldata oracleUpdate) external payable;
    function close(uint256 sizeFraction, uint256 limitPrice, bytes calldata oracleUpdate) external payable; // fraction in WAD
    function closeFor(address user, uint256 sizeFraction, uint256 limitPrice, bytes calldata oracleUpdate) external payable;
    function addMargin(uint256 amount) external;
    function removeMargin(uint256 amount) external;
    function liquidate(address user, bytes calldata oracleUpdate) external payable;
    function poke() external;
    function sweepFundingSurplus() external;                  // anyone; reserves pending funding obligations before sweeping to insurance

    // --- views (exact) ---
    function quoteOpen(int256 size) external view returns (uint256 avgFill, uint256 fee, uint256 marginRequired, uint256 newMark);
    function quoteClose(address user, uint256 sizeFraction) external view returns (uint256 avgFill, uint256 fee, int256 pnl, int256 fundingOwed);
    function health(address user) external view returns (int256 healthWad, bool liquidatable);
    function realizablePnl(address user) external view returns (int256 atCurrentReserves, int256 atTwapReserves);
    function curveAccounts() external view returns (uint256 curveBase, int256 entryCostNet, int256 clearing);
    function liquidationPrice(address user) external view returns (uint256);
    function maxOpenable(address user, bool isLong) external view returns (int256 size);
    function markPrice() external view returns (uint256);
    function indexPrice() external view returns (uint256 price, uint64 updatedBlock, bool isExternal);
    function fundingRatePerBlock() external view returns (int256);
    function openInterest() external view returns (uint256 longNotional, uint256 shortNotional, uint256 oiCap);
    function position(address user) external view returns (Position memory);
    function config() external view returns (MarketConfig memory);
    function status() external view returns (uint8, uint64 since);       // Active, Degraded, Paused, Settling, Settled
    function remark() external;                                            // Degraded → Active on a fresh price; anyone may call

    // --- creator ---
    function claimCreatorFees() external;
    function transferCreator(address to) external;
    function reseed(uint256 newDepth) external;                 // creator; only while longSize == shortSize == 0
    function declareSettlementEvent(uint8 kind, uint64 expectedBlock) external;
    function windDown() external;
}

interface IMarketFactory {
    function createMarket(CreateParams calldata p) external returns (address market);
    function predictAddress(string calldata symbol) external view returns (address);
    function markets(uint256 i) external view returns (address);
    function marketCount() external view returns (uint256);
    function isMarket(address) external view returns (bool);
    function listFeed(address adapter, bytes32 feedId) external;
}

interface IResolver {
    function propose(address market, uint256 price, string calldata evidenceURI) external;
    function dispute(address market, uint256 counterPrice) external;
    function finalize(address market) external;                // after window, no dispute
    function councilResolve(address market, uint256 price) external;
    function startStaleWindDown(address market) external;
    function state(address market) external view returns (uint8);
}
```

**Events** (all indexed by `market` and `user` where present; the indexer builds every table from these):

```solidity
event MarketCreated(address indexed market, address indexed creator, string symbol, bool isExternal, uint256 depth, uint256 seedBond);
event PositionOpened(address indexed market, address indexed user, address operator, int256 size, uint256 avgFill, uint256 margin, uint256 fee);
event PositionClosed(address indexed market, address indexed user, address operator, int256 sizeClosed, uint256 avgFill, int256 pnl, int256 funding, uint256 fee);
event MarginChanged(address indexed market, address indexed user, int256 delta);
event Liquidated(address indexed market, address indexed user, address indexed liquidator, int256 sizeClosed, uint256 avgFill, uint256 penalty, int256 badDebt);
event FundingAccrued(address indexed market, int256 ratePerBlock, int256 longIndex, int256 shortIndex, uint64 blockNumber);
event FundingSurplusSwept(address indexed market, uint256 amount);
event StatusChanged(address indexed market, uint8 from, uint8 to, uint64 blockNumber);
event BadDebt(address indexed market, address indexed user, uint256 amount, uint8 coveredBy); // 0 insurance, 1 backstop, 2 ADL
event AutoDeleveraged(address indexed market, address indexed user, int256 sizeClosed, uint256 price);
event FeesAccrued(address indexed market, uint256 protocol, uint256 creator, uint256 insurance);
event CreatorFeesClaimed(address indexed market, address indexed creator, uint256 amount);
event SettlementProposed(address indexed market, address indexed proposer, uint256 price, uint64 windowEnd);
event SettlementDisputed(address indexed market, address indexed disputer, uint256 counterPrice);
event MarketSettled(address indexed market, uint256 price, uint16 haircutBps);
event OperatorSet(address indexed user, address indexed operator, uint64 expiry, uint128 maxTotalNotional);
```

**Revert reasons** are custom errors with arguments, never strings: `Slippage(uint256 wanted, uint256 got)`, `OICapExceeded(uint256 cap, uint256 attempted)`, `StaleOracle(uint64 age)`, `InsufficientMargin(uint256 have, uint256 need)`, `NotLiquidatable(int256 health)`, `PolicyViolation(uint8 code)`. Agents parse these directly.

## Risk parameters

Two parameter sets, chosen by whether the market has an external index. Creators cannot override them; governance can update them per set with a 24-hour timelock.

| Parameter | Oracle-fed | Oracle-less | Notes |
| --- | --- | --- | --- |
| Max leverage | 20x | 3x | Health uses realizable PnL at TWAP reserves; oracle-fed also takes the worse of that and index PnL |
| Maintenance margin (`mmrBps`) | 250 | 1500 |  |
| Taker fee (`takerFeeBps`) | 8 | 8 |  |
| Creator share | 30% | 30% | Of taker and settlement fees |
| Insurance share | 30% | 30% |  |
| Liquidation penalty | 150 bps | 150 bps | 40% liquidator / 60% insurance |
| Partial liquidation threshold | 50,000 USDC | 10,000 USDC | Above this, close 50% per call |
| Skew coefficient `c` | 0 (Phase 2: 2%) | 0 (Phase 2: 5%) | Phase 2 target; c = 0 at launch (skew premium disabled) |
| Funding cap per period | 0.1% | 0.5% | Per 12,000-block period |
| Funding period `F` | 12,000 blocks | 12,000 blocks | About 1 hour |
| Skew funding `c_f` | n/a | 0.05 | Per period at full skew |
| Max oracle age | 10 blocks | n/a | Opens only; closes never read the oracle; Degraded after 100 stale blocks |
| Confidence pause | 100 bps | n/a | Opens pause above this |
| OI multiplier | 20 | 10 | `oiCap = insurance × multiplier` |
| Mark TWAP window | 300 blocks | 300 blocks | About 90 seconds; 600 blocks while Degraded |
| Proposal bond | n/a | 2,000 USDC | Resolver |
| Dispute window | n/a | 288,000 blocks | 24 hours |
| Stale wind-down | n/a | 90 days idle, 14 days notice |  |
| Backstop daily cap | 20% of backstop | 10% of backstop | Per market per day |
| Funding receive cap | 10× | 10× | Per-unit receipt vs per-unit payment; cap excess and rounding surplus sweep to market insurance after reserving pending obligations |
| Degrade after | 100 blocks | n/a | Primary stale and no fresh secondary |
| Degraded TWAP window | 600 blocks | n/a | Health reference while degraded; partial liquidations only |
| Max degraded | 2 days | n/a | Escalates to Guardian for wind-down |
| Impact margin (impactMarginBps) | 100% | 100% | Scales the impact minimum of initial margin; relax only with deep insurance |
| Side cap `C` | 128 bps of B0 (20x) | 1,010 bps of B0 (3x) | `sideCapBps = floor(10_000 × φ(λ))`; `C = floor(sideCapBps × B0 / 10_000)`; launch caps use 557 bps at 5x and 1,715 bps at 2x |
| Minimum seed bond | 5,000 USDC | 2,000 USDC | Sets initial insurance and OI cap |
| Depth minimum | `ceilDiv(oiMultiplier × bondWad × 10_000, sideCapBps)` | Same formula | Virtual; verify coverage again after reserve rounding; deeper always allowed |

**Launch caps for mainnet on October 13** (overrides until the audit pass is complete): max leverage 5x / 2x, per-user notional cap 2,000 USDC, per-market OI cap 25,000 USDC regardless of insurance, global deposit cap 100,000 USDC. All removable by governance without timelock during the first 30 days.

## Monad-specific constraints

Monad is EVM-equivalent at the bytecode level, so nothing here needs a special compiler; the differences are in how the chain schedules and charges for execution. Verify each item against the current Monad docs before relying on it.

**Parallel execution and storage contention.** Transactions in a block execute optimistically in parallel; any two that read or write the same storage slot are detected and re-executed in order. Design consequences, all already reflected above:

- One clone per market, so unrelated markets never share slots.
- No per-trade writes to global counters, treasury, backstop or leaderboards.
- `MarginVault` writes only `balance[user]` on the trade path. Two users trading the same market conflict on the market's slots (unavoidable, and correct); two users trading different markets never conflict.
- The indexer, not the chain, computes protocol-wide totals.

**Asynchronous execution.** Consensus orders transactions before they execute, so a transaction that reverts is still included and still pays. Every mutating call has an exact view twin; the SDK always simulates first and uses `limitPrice` to bound slippage between simulation and inclusion.

**Gas is charged on the limit.** As I understand Monad's fee model, transactions pay for `gas_limit`, not `gas_used`, to make the async model safe. Confirm in the docs; if so, the SDK must estimate tightly and add a small fixed buffer rather than the usual 20–30% multiplier, or agents overpay on every trade.

**Block time and finality.** 300 ms blocks with speculative finality well under a second. Staleness, funding periods, dispute windows and TWAPs are all denominated in blocks, never in seconds, so a block-time change is a parameter update rather than a rewrite.

**Execution events for keepers.** Keepers subscribe to Monad's execution event stream rather than polling logs. The liquidation keeper keeps an in-memory table of every open position's `liquidationPrice` and re-checks it on every `FundingAccrued` and price event; the first keeper to land the transaction wins the penalty.

**Pyth on Monad.** Pull oracle: the price update is carried in calldata and paid for by the sender. The SDK fetches the latest VAA from Hermes, attaches it to `open`/`close`/`liquidate`, and forwards the Pyth fee as `msg.value`.

**Reserve balance.** Monad reserves gas payment from the sender's balance at ordering time. Agents running many concurrent transactions need enough MON headroom for all in-flight gas limits, not just one.

## Off-chain components

Everything off-chain is derived from the events and views above; none of it holds state the contracts do not already have.

**Indexer (Envio).** One handler per event. Tables: `markets`, `positions` (current), `trades`, `liquidations`, `funding_samples`, `creator_earnings`, `leaderboard_pnl`, `leaderboard_creators`. Exposes GraphQL for the front end and a `/markets/:addr/book` snapshot for agents. Protocol-wide totals (volume, fees, TVL) live only here.

**Keeper (TypeScript, anyone can run).**

- Liquidation loop: subscribes to execution events, maintains `liquidationPrice` per open position, fires `liquidate` with a fresh Pyth VAA when index crosses it. Gas limit tight, nonce pool of 8 for concurrency.
- Funding poke: calls `poke()` on any market idle for more than 600 blocks.
- Sweeps: `FeeSweeper.sweep` hourly, `InsuranceBackstop.topUp` daily, and `Market.sweepFundingSurplus` monthly.
- Resolver: `finalize` after dispute windows; `startStaleWindDown` on idle markets.

**SDK (`@pripo/sdk`, TypeScript).** Generated from ABIs with viem. Adds: Hermes VAA fetch and attach, exact simulation before send, custom-error decoding into typed exceptions, operator-key signing, and a `Market` class with `quote`, `open`, `close`, `health`, `liquidationPrice`, `create`. Tight gas estimation per the Monad section.

**MCP server.** Wraps the SDK as tools: `list_markets`, `get_market`, `quote_open`, `quote_close`, `open_position`, `close_position`, `get_positions`, `get_health`, `create_market`, `propose_settlement`. Each mutating tool requires an operator key in the server config and refuses if the policy would be violated, so the model gets a clean error rather than a revert. Read tools are free; a hosted low-latency variant meters with x402.

**Reference agent.** A loop on Kimi or Qwen (bounty credits) that reads the three pre-IPO markets, forms a view from a small news feed, and trades within a 500 USDC policy. Second mode: watches an S-1 feed and calls `create_market` when a new filing appears. Runs on stage during the demo against a human trading from the UI.

**Front end (Next.js, Privy auth).** Pages: markets list, market detail with trade panel and creator earnings counter, portfolio, create market, settlement proposals. Reads from the indexer; writes through the SDK. Mobile-responsive is enough; a native app is out of scope.

## Testing and security

The vault and one market clone must pass invariant fuzzing before the factory, adapters or front end exist. A perp protocol's exploits live in the math and the ordering, not the UI.

**Foundry invariant suite** (handler-based, 10,000+ runs, depth 50):

- Cash equality: `vaultCashWad == Σ free + Σ locked + Σ clearing + Σ insurance + backstop + Σ owed + Σ skewPool + Σ fundingPool` after every handler call, with six-decimal USDC scaled by `10^12` before comparison.
- Exact conservation per market: `clearing == (Q − curveBase) − entryCostNet`, integer-exact, after every trade, liquidation and settlement.
- Entry cost and weighted-sum consistency: `entryCostNet`, `longWeighted` and `shortWeighted` equal their recomputed sums over open positions.
- Funding: `perUnit × payN − perRecv × recvN ≥ 0` in every accrual; `fundingPool × WAD + pendingHi == int(remainderHi) + int(roundingHi) − int(sweptHi) ≥ 0` at every step. `roundingHi` equals the sum of actual settlement rounding, each contribution is in `[0, WAD)`, and `roundingHi ≤ WAD × settlementCount`. Exercise both settlement orders, multiple accruals before settlement, fractional sizes, rate reversals, partial closes, changes of side and sweeps between settlements; no accrual while either side is empty.
- Funding sweeps: an equal payer/receiver obligation with no remainder or rounding permits no sweep, even after only one side has settled. A sweep transfers exactly `floor(surplusHi / WAD)` to insurance, preserves cash equality and leaves less than one quote wei of fractional surplus. A second sweep without intervening accrual or settlement transfers zero. Include a case where `sweptHi > remainderHi` because settlement rounding was swept, to catch unsigned subtraction.
- Solvency: every open position's realizable loss at current reserves is at most its margin, or the position is liquidatable; any shortfall on liquidation is emitted as `BadDebt` and paid down the waterfall in the same call.
- Impact margin and side cap after every open: worst-case loss at cap reserves `≤ margin − notional × mmr`; neither side's size exceeds `floor(sideCapBps × baseAtSeed / 10_000)` and neither side's quote notional exceeds the insurance bound. Depth tests use the stored integer cap and recheck coverage after integer reserve seeding.
- No free margin: `removeMargin` can never take health below the initial margin ratio.
- Liquidation completeness: after `liquidate`, the position is healthy, or its size is zero, or bad debt was recorded and covered.
- vAMM monotonicity: a larger long always gets a worse average fill than a smaller one at the same state; `longSize − shortSize == baseAtSeed − baseReserve` always.
- Degraded: opens revert, closes succeed with no oracle read, funding rate is zero, `remark` restores `Active` only on a fresh price.
- Settlement: after `Settled`, the sum of all withdrawals equals the sum of all margins plus PnL minus haircut, exactly, and `clearing == 0`.
- Reseed only at zero OI; afterwards `clearing == 0`, `entryCostNet == 0`, `Q == curveBase`, `B == baseAtSeed`.

**Unit tests** on the math library with known-answer vectors for fills, skew, both side-specific impact-margin formulas, all Funding regression vectors, zero and negative funding rates, applied side-cap rounding, depth minima and partial liquidation boundaries.

**Fork tests** against Monad mainnet with real Pyth VAAs for two feeds, including a stale-feed case and a high-confidence case.

**Attack scenarios to script explicitly**

- Self-liquidation for penalty: a user opens with a second wallet and liquidates themselves. Must be unprofitable after the 60% insurance split.
- Oracle-less mark manipulation: a whale pushes mark to liquidate the other side, then unwinds. Must fail because health uses the 300-block TWAP and exit impact lands on the manipulator.
- Skew farming: opening both sides to earn skew funding. Must net to zero after fees.
- Operator abuse: an operator exceeding policy, trading after revoke, or closing when `canClose` is false. All revert with `PolicyViolation`.
- Reseed griefing: creator reseeding to change entry prices. Must be a no-op on positions.
- Reentrancy through the USDC transfer hooks in vault `withdraw` and `claimCreatorFees`.
- Rounding direction on every division: always in the protocol's favour, proven by the conservation invariant.

**Static analysis**: Slither and Aderyn on every commit; ack3 scan before mainnet deploy.

**Review**: self-audit against the 33Labs checklist, then one external reviewer for the vault and market clone only. Launch caps (Risk parameters) stay in force until that review closes.

## Governance, operations and legal posture

Markets are immutable once deployed; the vault is upgradeable behind a timelock; a guardian can pause opens but never withdrawals. That split is the whole trust story and should be said in one sentence on the landing page.

**Upgradeability**

- `Market` clones point at a fixed implementation version. The factory can be switched to a new implementation for new markets; existing markets never change code. A market with a bug is wound down through the resolver, not patched.
- `MarginVault` is UUPS behind a 48-hour timelock with a guardian veto. Upgrades are announced with the diff and the review report before the timelock starts.
- Risk parameter sets change through a 24-hour timelock. The guardian can tighten (lower leverage, lower caps, pause opens) instantly and only loosen through the timelock.

**Roles**

| Role | Held by | Can | Cannot |
| --- | --- | --- | --- |
| Guardian | 2-of-3 multisig, team | Pause opens, tighten parameters, veto vault upgrades | Block withdrawals, touch balances, change fees |
| Governor | 3-of-5 multisig, team + advisors, timelocked | Parameter sets, implementations, treasury spend, council membership | Act without the timelock |
| Council | 3-of-5, independent | Resolve disputed settlements | Anything else |
| Keeper | Anyone | Liquidate, poke, sweep, finalize | Nothing privileged |

A governance token is a Phase 3 decision, not a Phase 1 promise.

**Treasury and insurance policy.** Fee sweeps land in a treasury multisig. The backstop target is 30 days of modeled worst-case bad debt across all markets; until it is met, 100% of the insurance surplus sweep goes to the backstop instead of 50%. Bad debt above the backstop is disclosed within 24 hours with the affected markets and the ADL applied.

**Monitoring** (alerts to the on-call channel): health distribution per market (share of OI below 1.5× maintenance), insurance drawdown rate, oracle staleness and confidence, skew above 60% of cap, keeper liveness (blocks since last liquidation check), indexer lag, vault solvency invariant re-checked every 100 blocks from a read-only watcher.

**Incident runbook.** Guardian pauses opens on the affected markets → keeper keeps liquidations running → assess with the watcher's solvency read → public statement within two hours naming the markets, whether user funds are affected, and the next update time → resume through the timelock or wind down. Never pause withdrawals.

**Bug bounty.** Live from the Phase 1 deploy, scaled to the deposit cap: 10% of funds at risk up to 50,000 USDC in Phase 1, raised with the caps.

**Legal posture.** Synthetic equity and pre-IPO exposure is the most regulated product category in finance, and the contracts do not change that. Mitigations: contracts are immutable and permissionless and hold no securities; the front end and hosted agent API are operated by a legal entity with geo-restrictions for restricted jurisdictions (United States and others on counsel's list) and terms of use; no marketing into restricted jurisdictions; counsel review completes before Phase 2 caps lift. This reduces the operating entity's exposure; it is not a guarantee, and the team should treat the entity structure as a Phase 1 task, not a later one.

## Build sequence

Phase 1 runs seventeen days from September 26 to the October 13 launch, contracts first with the front end and SDK in parallel once interfaces freeze on day 2. Referrals and the skew discount are in the day 3–5 scope because they change the fee path. Phases 2 and 3 follow below the cut list.

| Days | Deliverable | Done when |
| --- | --- | --- |
| 1–2 | Interfaces frozen, repo scaffold, math library with unit vectors | `IMarket`, `IMarketFactory`, `IResolver` ABIs committed; SDK codegen runs |
| 3–5 | `MarginVault` + `Market` clone: vAMM, funding, open/close, fees | Invariant suite green on vault + one market |
| 6–8 | Liquidation, partial liquidation, bad-debt waterfall, OI cap, operator policies | Attack scenarios scripted and passing |
| 9–10 | `MarketFactory`, `PythAdapter`, `NullAdapter`, `FeeSweeper` | Fork test opens an NVDA market with a live VAA |
| 11–12 | `Resolver`: propose, dispute, finalize, wind-down, settlement | Settlement invariant green; haircut path tested |
| 9–13 (parallel) | Front end, Envio indexer, SDK, MCP server, keeper | Human trade from UI, agent trade via MCP, on testnet |
| 14 | Static analysis, self-audit pass, ack3 scan, fixes | No high or medium findings open |
| 15 | Mainnet deploy with launch caps; three pre-IPO markets seeded; reference agent live | Real OI in all three markets |
| 16–17 | Demo video, write-up, submission; buffer | Submitted before the deadline, not on it |

**Cut list, in order, if behind schedule**

1. Reference agent's S-1 watcher (keep the trading loop).
2. `ChainlinkAdapter` (Pyth covers the demo).
3. Partial liquidation (full-close only, lower per-user caps to compensate).
4. `reseed` and `transferCreator`.
5. Resolver dispute path (propose + council-only for the demo; document the full flow).

**Never cut**: invariant suite, launch caps, operator policy checks, exact quote views.

**Bounties this build qualifies for**: Privy (auth), Envio (indexer), Chainlink CRE if the adapter ships, Nansen (creator and trader leaderboards), MetaMask agent wallet plugin (operator keys), Kimi or Qwen (reference agent), Chainstack (Track 01).

**After launch**

| When | Milestone | Depends on |
| --- | --- | --- |
| Week of Oct 20 | External review of vault and market clone scoped and started; bug bounty live | Launch deploy stable for 7 days |
| Nov 2026 | Review closed; caps lifted through the timelock; Telegram bot; market pages with OG images | No open high or medium findings |
| Nov 2026 | Points season 1 announced with the Foundation; Nad.fun graduation agent live | Indexer anti-wash rules shipped |
| Dec 2026 | Equity market-hours engine on mainnet behind a per-market flag; relayer and gas sponsorship | Pyth market-open flag validated across two closes |
| Jan 2027 | Cross-margin opt-in; Chainlink Data Streams adapter | Vault upgrade through the 48-hour timelock |
| Feb–Mar 2027 | Tokenized-stock collateral with Anchored tokens; ERC-8004 fee tiers | Collateral liquidation path through Kuru tested on fork |
| Apr–Jun 2027 | Reputation-based margin; creator-role marketplace; governance token decision | Backstop at 30 days of worst-case bad debt |

Each milestone lands only when its dependency is met; dates move, dependencies do not.

## Trading-runtime implementation notes — September 28

The liquidation/backstop milestone implements `IMarketCore`, including `liquidate`, with `IMarket` retaining the planned exact risk views and resolver surface. The concrete contract ABIs are the SDK's `marketAbi` and `marginVaultAbi`; `plannedMarketAbi` must not be treated as the current runtime ABI. The Phase 2 vault functions above remain design reservations, not deployed selectors.

- `Position.margin` reports the positive part of signed locked collateral; `positionDebt(user)` reports the negative part. Pending funding remains separate until settled. The two values cannot both be positive.
- `quoteOpenFor(user,size)` includes pending funding when calculating the additional collateral required. Opens add to the same side; users close to zero before changing sides. Partial closes retain collateral, and excess can be removed through the initial-margin and reference-health checks.
- Zero-quote opens revert. An existing dust position can close even when its quote amount rounds to zero; the exit still updates base reserves, entry cost and funding contributions exactly.
- Closes ignore their oracle-update bytes and reject nonzero native value. They use cached observations and never call an adapter. Opens, `poke` and `remark` can observe fresh primary/secondary prices; guardian pauses survive these refreshes.
- Funding is accrued with the previous cached observation before a new price is installed. A stale interval stops accruing at the first degraded block; a refresh does not apply the new price retroactively.
- USDC fee claims transfer whole six-decimal units and retain fractional WAD dust in the originating owed account.
- Liquidations execute at curve reserves with capped 150-bps penalties and insurance/backstop coverage. Normal partials complete if their remainder is unhealthy after the penalty. Degraded liquidations retain the 50% per-call limit, except the last base wei; their remainder may require another liquidation.
- Both liquidations and voluntary full closes cover market insurance first, then the global backstop within a fixed 288,000-block per-market window. Each window snapshots 20%/10% of the then-available backstop; later contributions do not refill that allowance.
- ADL and terminal shortfall handling remain incomplete. `UncoveredBadDebt` currently reverts the entire transition if insurance/backstop coverage is insufficient. The reference-price versus curve-price ADL descriptions and the exhausted-waterfall payout guarantee need economic decisions before implementation. This limitation does not amend the target payout guarantee above.
- Factory/adapters, remaining exact risk views, resolver settlement and Monad fork validation remain subsequent milestones; the complete payout guarantee is a deployment gate.

See `docs/implementation-notes.md` for deployment sequencing, linked-library requirements and the remaining integration work.
