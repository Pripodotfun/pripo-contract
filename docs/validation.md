# Contract validation

The current risk-view stage validates **223 local tests**, **28 fuzz properties at 10,000 runs each**, and **2,500,000 invariant handler calls with zero reverts**, across the full CI run and corrected-fixture rerun described below. Prior Monad integration verified **18 opt-in fork tests**; **five offline tooling tests** also pass. Earlier sections retain the tested history and its scope.

The October 2 stage integrates reserved pending ADL into the production market/vault paths. It replaces allocation search with fixed schedules, funded rounding, stable slots and permissionless fallback; settlement requires a fresh full-book insufficiency proof. Validation uses a proxy vault, immutable market clones and six-decimal mock USDC with actual ERC-20 transfers. That stage's full CI campaign passed **169 tests**, **20 fuzz properties at 10,000 runs each**, and four invariant suites at 10,000 runs/depth 50: **2,000,000 handler calls with zero reverts**. Earlier sections retain the implementation/design history; their former dust and allocation-search gates are superseded. Funding now clamps to payer collateral as described below; target-chain gas validation remains a deployment gate.

## Reproduce

```sh
make build
make ci
make analyze
```

The CI profile runs each fuzz property 10,000 times and each invariant 10,000 times at depth 50. `fail_on_revert = true` prevents the handlers from silently discarding reverted operations. The funding/trading end-of-run checks close every position and sweep the remaining funding surplus. The real-token trading suite additionally requires zero curve clearing and entry cost, with reserves restored to their seed values. The separate capital suite checks custody transitions against terminal-market stubs. The fourth suite exercises actual market liquidation, ADL and forced settlement using explicit legacy-debt fixtures. The fifth suite checks production funding capacity and receiver-first cash withdrawals across two markets without liquidations, injected debt or recapitalization.

The market handler exercises opens/increases, partial/full closes, margin changes, block advances, funding sweeps, claims, deposits and withdrawals across eight traders. It recomputes signed cash equality against the token balance, entry-cost and weighted-index sums, base exposure, and the exact funding-surplus identity after every call. Opens assert impact margin and both side caps. The bounded campaign uses at most 18 base units per trader and 12,000 blocks per advance; it does not model exhausted-insurance liquidation. Long-idle production regressions now require funding to clamp before exhausting protected collateral. The separate backing suite includes 100-million-block gaps and full receiver-first unwinds.

On this macOS installation, sandboxed `forge test` crashes in the system proxy settings library before test execution. Tests were run outside that sandbox, without an RPC or private key. Upgrade-delay tests read the scheduled deadline from the contract instead of reusing `block.timestamp` across `vm.warp`, because the IR optimizer may cache a transaction's timestamp.

## Static analysis

| Tool | Version | Result |
| --- | --- | --- |
| Forge source lint | 1.5.1 | No warnings in `src/` |
| Slither | 0.11.5 | 64 contracts analyzed, 101 detectors; five low timestamp findings, one informational assembly finding and four informational complexity findings after scoped annotations |
| Aderyn | 0.1.9 | 37 project source files, 63 detectors; five high categories and five low categories, reviewed below |

The size gate passes: Market is 20,979 bytes, MarketTrading 7,514, MarketLiquidation 7,023, MarketMargin 3,254, MarketAdl 19,942, MarketSettlement 8,474, MarketAccounting 9,564, MarketLens 8,415, MarketFundingCapacity 5,421, MarketMaintenance 4,828, MarginVault 20,014 and MarketFactory 13,091 with the pinned compiler/settings. Every production component fits EIP-170’s 24,576-byte limit; Market retains 3,597 bytes of headroom. All fifteen JSON ABIs and the TypeScript constants are regenerated and pass freshness checks. A strict TypeScript import/method/tuple-boundary check covers the funding-capacity views, reserve-floor mutability, factory overloads and removal of the obsolete `RESERVE_BLOCKS` getter. Exact remaining risk views and resolver integration remain future work.

The Aderyn command explicitly sets `FOUNDRY_EVM_VERSION=cancun` to match the project. This installed version otherwise fails while parsing a `prague` default. Dependency/test path filters use `lib/` and `test/`, including the slash, so they do not accidentally exclude `src/libraries/`.

### Aderyn triage

- **Unprotected initializer, high:** `RiskMath.initialMargin` and `MarketAccounting.initialMargin` calculate margin and do not initialize storage. `MarkTwap.initialize` is a linked Solidity library function with a storage reference and an explicit nonempty-state rejection; its market call is inside the registrar-authorized, `initializer`/`nonReentrant`-guarded initialization. Clone and implementation initialization, repeat initialization, and initialization callbacks are tested.
- **Tautological comparison, high:** `MarketAdl._before` and `FundingCapacityHeap._less` compare fields of two different instances. The analyzer identifies their common struct members as identical operands; these are not self-comparisons. Multi-candidate ordering, invalid ordering, reverse-ordered full-book ADL and heap tie/order properties exercise the comparators.
- **Storage array edited with memory, high:** four heap calls pass stored nodes to the pure `_less` comparator. It only reads the copied nodes and returns their ordering; no mutation of a memory copy is intended. `set`, `remove` and `_swap` write the storage array and index mapping explicitly. Sequence fuzzing checks every mapping index, parent ordering and the minimum against a full scan after each mutation.
- **Unchecked return, high:** open/addMargin/removeMargin/liquidate, paired ADL and terminal execution call `settleFunding` for its state and ledger effects. Those paths need the state/ledger effects; all callers still execute the settlement and propagate reverts. Voluntary close also ignores the total returned by `coverDebt`, which emits the required per-source debt events itself. Terminal execution ignores `finalizeSettlement`’s returned amount because the vault emits sources and stores the deficit; the caller reads stored deficit for liquidation reporting. Continuation/fallback ignore `_run`’s liquidation-summary return while its state effects and events remain authoritative. Terminal reservation release ignores the returned aggregate because the vault records the source returns; no success result is discarded.
- **Locked Ether, high:** the vault's inherited payable UUPS override rejects native value. Non-degraded external-index open/remark/liquidate forward all supplied value to the primary adapter; oracle-less calls, degraded liquidation and every close reject it. Adapter failure with value reverts atomically. The factory forwards creation-update value to its approved source; Pyth forwards the exact fee to its immutable provider and rejects extra value; NullAdapter rejects all value. Tests check forwarding, rejection and zero retained market/factory/adapter balances on these paths.
- **Public visibility, low:** UUPS uses the inherited public override signature. Linked libraries are deliberately public so their code is deployed separately instead of copied into Market.
- **Repeated literals, low:** these are fixed launch parameters validated at initialization, including window lengths, funding periods and risk sets. Governance parameter changes are a later integration.
- **Event indexing, low:** the events follow the spec's indexed market/user identifiers. Numeric amounts remain in event data. Adding indexed fields would alter the public event surface without serving the specified indexing needs.
- **Large numeric literal, low:** `10_000` denotes the basis-point denominator. This spelling is intentional.
- **Internal functions called once, low:** reusable math primitives are intentionally kept as named functions. The optimizer can inline internal functions.

Slither's foundation findings for an implicit zero initialization and divide-then-multiply sweep accounting were fixed directly. Runtime annotations are limited to the reviewed nodes/functions: exact zero/enum discrimination, deliberately unused simulated state, and guarded oracle/vault calls. Every mutating market entry point, including initialization, holds `nonReentrant`; the only adapter callbacks observe the pre-trade checkpoint, and vault ledger methods do not transfer tokens; coverage calls the bound backstop controller, whose market/vault reads are static. Callback tests verify rejection during trading and bootstrap. The new whole-book loop annotations document the 128-account limit, fixed vault target and enclosing market guard. These annotations do not disable detectors project-wide and need review when affected call paths change. Slither’s four complexity findings remain visible in ADL dispatch/matching, liquidation dispatch and factory creation. Timestamp findings cover the vault upgrade delay, adapter/implementation activation, bond maturity and Pyth age checks; these are deliberate clock comparisons, with boundary tests. The bounded loops use only the fixed vault under the enclosing market guard; their ledger-only methods transfer no tokens. Reservation initiation calls the bound backstop controller, which makes only static vault/market reads. Continuation, multiple-reservation, zero-allowance, full-book and terminal regressions exercise these paths. Local initialization warnings were resolved explicitly; the high limb of `mul512` alone is intentionally used for score saturation. The retired `IncompleteAdlCandidates` error was removed.

## Vault stage

Ten vault tests cover custody, isolated debt, balanced funding/PnL/insurance transfers, claims and dust, referral binding, operator expiry/revocation/spending/Merkle scope, deposit caps, initialization, upgrade delay/veto/storage, callback reentrancy, and transfer-tax rejection.

Slither's added timestamp finding is the deliberate 48-hour governance delay. Aderyn additionally flags inherited payable UUPS upgrade entry points as potentially locking Ether; the override rejects nonzero `msg.value`. Its `public` visibility is required by the inherited UUPS signature. No ordinary vault operation accepts native tokens. Modifier ordering was corrected. Existing math and event/style findings remain as described above.

## Runtime stage

Integration tests cover quote/execution agreement, increases and partial-close dust, winner withdrawals before the loser closes, receiver-first funding, isolated funding debt, margin removal, launch caps, slippage, operator enforcement and atomic policy consumption, referrals and fee claims, guardian pause/resume, zero-OI reseeding, creator transfer, initialization, two-market isolation, stale/confident/broken oracles, secondary fallback, native fee forwarding, cached-price accrual, same-block TWAP manipulation, ring wrap/interpolation, and oracle callback rejection.

That runtime stage did not include ADL or terminal execution. The current stage adds those local tests below; no Monad fork, live oracle adapter, deployment or external audit is claimed.

## Backstop and module stage

The preceding backstop/module stage passed **72 tests**, including all 65 prior tests and seven new backstop tests. Both invariant suites ran 256 sequences of depth 50 with zero reverts. New tests cover insurance-first coverage, per-market 20%/10% budgets, window expiry and the genesis-block boundary, no refill from repeated claims or new funding, surplus reserve retention, capped/self-liquidation penalties, locked-only debt transfers, authorization and cash equality. Market integration tests continue to exercise linked-module callbacks and native update fees.

The market refactor uses namespaced storage and fixed linked libraries. All production components remain below the runtime limit. The default campaign checks existing trading behavior; it does not validate an ADL selection algorithm or a terminal shortfall policy.

Static review of the new controller call: `coverBadDebt` is guarded and calls the governor-bound controller, whose implementation performs only static reads of the registered market and vault before updating its own budget. Registered market code remains trusted. Module oracle targets come from validated immutable configuration; supplied native value is forwarded only to that configured adapter. The corresponding analyzer annotations are scoped to these calls. Storage-pointer assembly assigns one fixed namespace; it does not accept a caller-selected slot.

## Liquidation stage

Fourteen new integration tests (including the two-sided funding fuzz property) and two sizing/rounding tests cover: fresh-index liquidations at actual curve prices, exact penalty/event accounting, healthy/empty rejection, retained healthy partials, completion of unhealthy normal partials, guardian pauses, paid updates and callback rejection, stale-price rejection, degraded half-only closes and final base-wei dust, insurance/backstop coverage, a receiver closing and withdrawing before the debtor, atomic rollback when coverage is exhausted, and voluntary full-close backstop coverage. Fuzzing checks both healthy rejection and liquidation, then unwinds the market and asserts cash, curve and funding identities. Degraded funding-debt fixtures use a longer configurable outage threshold to reach these states through real accrual, without modifying contract storage.

The new event-reentrancy annotations are scoped to guarded liquidation and coverage functions. The callback test exercises the linked liquidation entry point; the actual backstop controller has no state-changing callback. `coverDebt` deliberately ignores no success flag: a vault/controller failure or remaining shortfall propagates as a revert.

The stateful market handler still covers trading and funding rather than arbitrary liquidation sequences. Liquidation coverage comes from the integration/fuzz suite; no complete ADL waterfall invariant is claimed.

## Terminal-funding specification update

The preceding documentation stage defined paired ADL, terminal local-fee absorption, an uncapped terminal backstop draw, a protocol reserve, and deficit repayment on already-settled markets. That stage retained the earlier 88-test implementation scope. It also restored signed collateral, six-decimal USDC/WAD conversion, exact funding-rounding accounts and applied integer side caps from the implementation.

Specification checks cover six-step source order, reserve-floor units and aggregate market-count examples, balanced terminal-deficit/repayment entries, Phase 1 `deficit > 0 ⇒ Settled`, treasury sweep gates, and the distinction between accounting equality and actual cash backing. At that specification stage the vectors were future implementation requirements. Current reserve and terminal tests cover source transitions and signed clearing; full cash-backing enforcement remains a launch gate.

## Reserve and terminal-capital stage

Fourteen new unit tests cover admission ceiling/rounding and the eleventh oracle-less market, zero-rate admission, persistent budgets through pauses and zero exposure, terminal source boundaries under fuzzing, local-fee isolation, uncapped terminal backstop use, reserve exhaustion and residual deficit, state/exposure/authorization checks, repeat-finalization rejection, duplicate debtor handling, fee repayment order and address ties, bounded progress across 34 deficits, pruning targeted repayments, sub-token dust, partial reserve refill, treasury gates, external and free-balance contributions, emergency deposit-cap bypass, upgrade storage persistence, taxed-token rejection and callback reentrancy.

Two new clone integration tests create a synthetic terminal obligation on a separate registered stub. They verify that actual owner/operator opens and governor resume are blocked, failed opens do not consume operator allowances, existing close/withdraw paths remain callable, admission rolls back below the reserve floor, and admission/opening can resume after recapitalization and refill. The dead stub remains settled.

The new eight-market capital invariant randomizes fee accrual, terminal custody, external funding, targeted recapitalization, free-balance donations, partial allocations, time advances and treasury claims. It recomputes actual token cash including reserve minus deficits, deficit totals, terminal states, admitted budget totals, repayment priority and exact treasury transfers. Every successful sweep asserts the reserve floor and zero deficit. Synthetic obligations are balanced against the funding pool to isolate custody; this is not a simulation of market liquidation pricing or whole-book settlement.

Static review found two new unused-return reports: terminal status ignores the transition block, and heap removal ignores the already-read root. Both received narrow annotations explaining the intentional omission. Capital-account mutations share the token-transfer reentrancy guard. The prior timestamp/assembly findings and Aderyn categories remain as triaged above. Storage additions are append-only; no vault base contract or pre-existing field moved.

That reserve stage did not establish whole-book execution or full cash backing after a deficit. The following stages add enumeration and terminal execution with a 128-position bound inside the 256-address custody limit. Funding-lag cash backing remains unresolved.

## Bounded-book stage

The original book-stage tests covered the full 256-position limit and rejection of a 257th account; current tests use the reduced 128-position limit and reject the 129th account. Coverage also includes increases and partial closes at capacity, slot reuse on full close, swap removal, pagination boundaries, reopening and full liquidation removal. The real-token trading invariant now compares registry cardinality to nonempty positions and checks every returned account is unique and open. At that stage all 108 default-profile tests passed; all three invariant suites ran 256 sequences of depth 50 with zero reverts. Size, lint, ABI freshness, Slither and Aderyn gates pass with the existing triaged findings. No complete-settlement gas bound is claimed by the registry tests.

## Paired ADL and forced-settlement stage

At the original settlement stage, six ADL integration tests covered long and short targets, unchanged virtual reserves, exact paired clearing, partial winner collateral release, automatic and explicit candidate selection, multiple ordered candidates, invalid/duplicate/wrong-side rejection, truncated-list rollback and the integer-fragment liveness boundary. The 128-position boundary fixture formerly reverted after greedy allocation left one base wei. The redistribution stage below changes that regression to require successful exact pairing.

Six settlement integration tests cover pending funding profits and exact pro-rata haircuts, already-withdrawn winners and a real terminal deficit, cash recapitalization without reopening, long/short and receiver-departure fuzzing, both signs of terminal clearing, and the 300-block terminal TWAP during a degraded 600-block health regime with a broken adapter. Two signed-clearing tests use a guarded test-only settlement entry point to value healthy unmatched exposure; production settlement remains reachable only through liquidation's complete-book eligibility check. Every actual terminal path checks zero open sizes, positions, clearing and funding pool. The old uncovered-liquidation rollback regression now verifies complete terminal handling; voluntary full-close rollback remains intentional.

The new four-actor liquidation invariant starts from a real funding-lag fixture and randomizes liquidation, block advances, margin additions, partial closes, withdrawals, actual reserve contributions and fee allocation. It checks cash/curve conservation, position and funding-weight totals, funding surplus and terminal-only deficit after every call. It passed 500,000 calls with zero reverts. Withdrawal amounts are bounded by actual vault cash: this suite deliberately checks balanced transitions and does not prove all nominal entitlements can be withdrawn simultaneously. Base-wei allocation is covered by the explicit regression above, not hidden by catching handler reverts.

### Gas regression scope at the settlement stage

| Local Cancun scenario | Gross gas for liquidation | Gate |
| --- | ---: | ---: |
| Complete 128-position book, preflight plus forced settlement | 15,634,750 | < 20,000,000 |
| 128-position book, automatic ranking and 125 paired winners in adverse score order | 11,418,767 | < 20,000,000 |

Measurements use `gasleft()` around liquidation and include execution before storage refunds. They exclude fixture creation and deployment. The earlier 256-position terminal case used 34,569,639 gross gas and failed the local budget, prompting the enforced 128-position cap. These measured fixtures provide regression bounds, not an exhaustive proof across every storage/oracle configuration. Validate target-chain execution, worst-case fresh update costs and the full supported state domain on a Monad fork before deployment.

That settlement-stage CI campaign completed all 27 suites in about 292 seconds. Formatting, size, production-lint and ABI checks pass. Slither exits successfully at the medium threshold, and Aderyn's reported categories are triaged above. That stage left integer-fragment ADL liveness, funding-lag cash backing and target-chain gas validation open. The next stage repairs the reproduced greedy failure while retaining the remaining policy and proof gates.

## ADL boundary redistribution stage

The original 128-position, one-base-wei remainder now closes successfully through paired ADL. New integration cases cover explicit lists for both long and short targets, preserving aggregate matched size, score order, reserves and signed cash equality. The earlier winner retains a small open slice instead of being fully closed; the final winner receives a larger profitable slice. Unused protocol reserve and zero deficit are checked in the full-book regression.

Eight rounding/planner tests cover a sufficient executable-slice bound, negative collateral, exact valid slices below that bound, zero-equity matches, whole-match replacement with order preservation, rejection of payouts over remaining debt, unchanged allocations when redistribution fails, and bounded unsuccessful search. The bound property runs 10,000 inputs and asserts strictly positive realized profit, nonnegative slice equity and compatibility with the vault release guard. Unit planner fixtures use synthetic candidates; the full-book and two-sided regressions use actual market/vault accounting.

Redistribution is limited to **512 pair checks per plan**, including repeated unsuccessful candidates. Candidate indices are carried in memory, and unprofitable slices are rejected before allocating match data. An explicit list and its separate automatic completeness check each receive one budget. Consuming that work budget never counts as proof of book exhaustion. The new test limits the search alone to three million gross gas, separately from market enumeration and execution.

| New local scenario | Gross gas | Gate |
| --- | ---: | ---: |
| 128-position book with repaired rounded boundary, actual liquidation | 7,763,515 | < 20,000,000 |
| 512 pair checks followed by remaining candidates, zero-profit fragments | 1,213,394 | < 3,000,000 |
| Same bounded search, positive profit but insufficient slice equity | 1,785,822 | < 3,000,000 |

The uncapped candidate-pair search initially exceeded its planning budget; the fixed work limit and memory-only search address that measured cost. These unit gas measurements do not constitute a target-chain maximum for every liquidation or oracle update.

**Remaining scope:** the reproduced greedy defect is fixed, but bounded redistribution is not an exhaustive integer-partition solver. Some books have no exact strictly profitable partition at all (for example, two 100-base-wei shorts with entry proceeds 10,001 quote wei and a paired price of 100 WAD cannot fill a target of 101 while both profits remain positive). The policy for provably indivisible dust is unresolved. Existing guards continue to reject an incomplete allocation with enough full eligible size; they do not allow a caller to force settlement. General ADL liveness, funding-lag cash backing and Monad fork validation remain launch gates.

The final redistribution CI campaign completed **28 suites / 133 tests** in about **299 seconds**, including all four 500,000-call invariant campaigns without reverts. Formatting, size, production lint, ABI freshness, Slither and Aderyn gates pass. There are no runtime ABI changes in this stage. Slither retains its six previously triaged results; Aderyn retains four high and five low categories with the same triage. The bound and release checks add no storage fields, token transfers, external callbacks or new coverage sources.

## Constructive ADL policy: code compatibility checks

The selected replacement policy uses whole-position exact profit eligibility, greedy chunks, a one-quote-wei insurance/reserve payment for rounded-zero profit, and `AdlZeroProfit` only when both sources are empty. Forced settlement remains conditional on insufficient eligible size. No allocation search result authorizes settlement. Runtime integration is pending the funding-debt eligibility decision below; the current matcher still uses the preceding redistribution implementation.

Three new regression tests pass against the existing math and vault:

- An exactly profitable short with size `1e18`, entry proceeds `100.2e18` and paired price `100.015e18` allocates a one-base-wei chunk **100 quote wei of entry and 101 quote wei of buyback**, booking a loss of one quote wei. A one-wei payment raises net profit only to zero. The proposed correction is to round ADL short-winner entry allocations up alongside their shared buyback value; long-winner entry allocations stay rounded down. Both legs must continue to use the same paired quote, with the actual removed entries reflected in `entryCostNet`.
- A full close with post-funding collateral of -2 USDC and positive trading profit of 1 USDC leaves -1 USDC of isolated debt. Profit-only eligibility cannot guarantee a debt-free full close. Dust payments into free balance do not discharge this debt.
- A half close with whole-position collateral of -10 USDC and whole-position trading profit of 20 USDC has allocated equity of +5 USDC. Realizing its 10-USDC profit brings total locked collateral to zero. Releasing the apparent 5-USDC payout would leave negative collateral on the remainder, so the actual vault rejects it. Requiring nonnegative whole-position equity alone does not solve the partial-close case.

The funding-policy recommendation is to require nonnegative post-funding collateral as well as exact positive trading profit for ADL eligibility. Keeping profit-only eligibility instead requires explicit funding-debt recovery and payout rules. That choice changes which positions count toward the terminal size trigger and has not been inferred from the dust decision.

Implementation ordering must reserve or consume planned liquidation coverage before spending insurance on dust; otherwise the same insurance wei can be promised twice. Reserve-funded dust is a new live-market exception to terminal-only reserve spending. Under the existing gate, any draw below `reserveFloor()` blocks opens and resume until refill. One quote wei is `10^-18` USDC in the ledger; one raw six-decimal token unit is `10^12` quote wei.

Validation for this stage: the three targeted regressions and formatting pass. Production contracts and ABIs are unchanged; the previous full CI result above has not been rerun for these test/documentation additions.

## Pending ADL design checks

The subsequent decision accepts nonnegative post-funding collateral for candidates, reverses shared-quote rounding to favour winners, and replaces eligible-book exhaustion with opposite-side size exhaustion or a 1,000-block pending deadline. This supersedes the proposed eligibility and trigger rules in the preceding section. The pending lifecycle is not yet implemented.

### Rounding and the total coverage bound

With shared quote rounded down for short winners and up for long winners, and their allocated entries rounded in their favour, rounded chunk profit is at least exact chunk profit. Since exact eligibility is strictly positive, integer chunk profit is **at least one quote wei**. The zero-profit/top-up path is therefore unreachable under these directions. A 10,000-input property checks the exact rational inequality by cross multiplication for both sides, including partial and full chunks.

The target's old price boundary does not reserve the cost of this favourable rounding. Two regressions demonstrate the resulting budget violation:

- Long target: size 3 base wei, entry 10 quote wei, allocated margin 1 and coverage 1. The boundary is `ceil(8 * WAD / 3)`. Three one-base-wei matches each pay the long 2 quote wei after rounding down, for a total of 6. Required coverage is `10 - 1 - 6 = 3`, exceeding the budget of 1, while all three short winners remain exactly profitable.
- Short target: size 3, entry 8, allocated margin 1 and coverage 1. The boundary is `floor(10 * WAD / 3)`. Three one-base-wei matches each cost the short 4 quote wei after rounding up, for a total of 12. Required coverage is `12 - 8 - 1 = 3`, again exceeding the budget of 1, with profitable long winners.

This shortfall is paired-fill rounding loss on the target, not a zero-profit payment to a winner. Keeping the new directions requires an explicitly funded rounding allowance within the total committed budget and an integer-aware price calculation. Per-continuation replenishment cannot silently increase the original budget. The shared quote still preserves clearing exactly; accounting conservation alone does not enforce the coverage ceiling.

### Pending custody and lifecycle requirements

- Nonnegative winner collateral and positive rounded PnL make the existing winner release guard compatible with pro-rata nonnegative margin allocations. The pending loser can still have negative collateral. A new vault regression starts at -10 USDC, realizes +12 on a partial pairing and proves that the apparent proportional refund of 7 cannot be released from the resulting total locked balance of 2. Retaining target refunds while pending, and enforcing collateral requirements for any unselected residual exposure at completion, avoids releasing through remaining debt.
- `liveCoverage()` is a current availability view, not a reservation. Insurance can fund other closes, the backstop can fund other markets, its daily allowance can roll over, and terminal coverage can consume its remaining balance. Pending coverage requires actual vault/controller reservations, excluded from other spending and counted exactly once in the cash identity. Reserve the backstop allowance once, consume only the reserved remainder on continuation, and release or consume reservations on completion and terminal settlement.
- `{remainingSize, since}` alone cannot track the fixed financial commitment. The implementation also needs the selected entry/margin allocation, committed coverage and cumulative use (or equivalent derived state). Starting penalty is charged once. Continuations never reset `since` or acquire a fresh daily budget. Pending-owner closes, margin removal and use of that position in another pairing must either reconcile the commitment or be rejected. Margin additions need an explicit treatment without silently resetting the loss bound.
- `Paused` currently continues funding accrual. A fixed initial margin/coverage bound can be eroded between transactions. A pending funding rule is required: for example, checkpoint and freeze market funding until all pending liquidations resolve, or separately reserve and account for additional accrual. A deadline does not execute a transaction or stop funding by itself. Clarify that the paired-continuation bound does not cover a terminal TWAP valuation unless terminal accounting is also changed; the terminal waterfall can currently consume capital beyond live coverage.
- Negative collateral alone does not currently authorize liquidation. `MarketLens.health` compares total equity, including realizable PnL, with maintenance. Making every funding-indebted candidate liquidatable requires an explicit predicate change in both the view and execution path.
- ADL pause state must remain independent of the Guardian pause and oracle degradation. `poke`, `remark`, and governor resume currently restore Active when their existing conditions allow it; they must respect all pending positions. Completion of one pending position cannot clear another's pause. An expired pending liquidation needs a permissionless completion/settlement path that does not reset its timer or charge another penalty.

### Caller omissions and timeout semantics

The current runtime already checks the complete canonical book before settling. The existing `testOmittedEligibleCandidateCannotForceSettlementAndRollsBack` regression passes: an empty list rolls back when the automatic plan can finish. The stated empty-list force-settlement exploit is not present in this revision.

The proposed timeout is a new policy tradeoff: a caller can submit an empty list for a genuinely ADL-needing position, enter pending and start the deadline even when a complete list exists. Unless someone completes it before expiry, the timeout permits settlement. This is a bounded opportunity for keeper recovery, not proof that counterparties were unavailable. Transactions are still required to make progress or execute the timeout.

Validation: four new tests pass, including the 10,000-input rounding property, alongside the existing omission-protection integration test. Formatting and diff checks pass. Runtime contracts, ABIs and the protocol spec are unchanged in this compatibility-review stage.

## Value-scheduled pending ADL checks

The latest decision retains loser refunds in locked collateral, requires actual per-position coverage reservations, freezes funding while any pending ADL exists, and adds negative post-funding collateral to the liquidation predicate. Terminal settlement again requires a current, complete-book eligible-size check. The deadline only enables permissionless, batched enumeration; elapsed time is not a settlement trigger. Value schedules replace rounded price multiplication. These decisions describe the intended replacement; the production matcher remains unchanged at this review stage.

### Freeze and telescope the selected entry allocation too

At initiation, snapshot original selected size `S0` and selected entry `E0 = floor(positionEntry * S0 / positionSize)`, taking all entry on a full selection. Also snapshot the base paired value `V0`. For cumulative matched size `d`, maintain both prefixes:

```text
entryPrefix(d) = floor(E0 * d / S0)
valuePrefix(d) = floor(V0 * d / S0)
```

Each chunk removes the difference of entry prefixes and pairs the difference of value prefixes. Apply the actual removed entry to the position and signed `entryCostNet`. Neither denominator nor the initial totals are recomputed from the shrinking position. At completion the selected entry removed is exactly `E0`, the base paired value is exactly `V0`, and any unselected exposure retains exactly `originalEntry - E0`.

The existing `Curve.closedEntryCost` cannot simply be reapplied to the remaining position on every continuation. A regression selects 2 of 4 base wei from entry 402 quote wei. The intended selected entry is 201, but two successive one-unit allocations using the shrinking position remove 100 + 100 = 200. A short with scheduled buyback 204 then loses 4 instead of its intended budget of 3. Fixed entry prefixes remove 100 + 101 and restore the exact budget. Full-position completion eventually removes all residual entry under either method; the discrepancy matters when the pending selection is only part of the original position.

### Budget and invariant definitions

- If total reserved coverage is `C0` and rounding reserve is `R`, only `C0 - R` can support paired losses. The paired-loss budget is `B0 = M0 + C0 - R`, with `M0` the signed selected post-penalty collateral. Set `V0 = E0 - B0` for a long and `V0 = E0 + B0` for a short in the nonnegative value domain. Using `M0 + C0` for pairing and also reserving `R` from the same `C0` double commits the allowance. If `C0 < R`, the specified reservation cannot be funded; an additional rule/source is needed. Insufficient allowance is not itself eligible-size exhaustion.
- Added margin can replace unspent loss-coverage reservation one-for-one, without consuming the rounding reserve or changing `S0`, `E0`, `V0`, matched progress or the original deadline. Excess deposits remain collateral. Restarting the schedule after an addition or returning already-consumed coverage would invalidate the cumulative accounting.
- Only **base scheduled** chunks sum to `V0`. For a long target, actual value is `max(scheduled, realizableFloor)`; for a short it must be `min(scheduled, realizableCeiling)`. Record relief separately: final actual value is `V0 + relief` for a long and `V0 - relief` for a short. Final trading loss is `B0 - relief` in both cases. Winner top-ups remain separate reservation-to-free entries.
- Candidate eligibility must use the exact `V0 / S0` ratio and preserve the positive close-alone realizable-profit check. The realizable clamp changes actual values, so profit at the base schedule alone is insufficient. Use full-precision rational comparisons, not a display price rounded to WAD.
- The schedule's incremental value is a floor or ceiling of the exact chunk value. Winner-favouring entry rounding keeps booked chunk profit nonnegative, and one reserved wei raises a zero to one. The previous stronger invariant `rounded profit >= exact profit` no longer holds: a short chunk with exact profit `7/6` can book and receive `1`, so it receives no zero-profit top-up. Use nonnegative booked profit, positive paid profit and the one-wei top-up bound instead.

### Chunk limits and enumeration

A lifetime cap of 64 chunks conflicts with the existing 128-position book and complete-book-only settlement trigger. A regression uses one 65-unit loser and 65 individually profitable one-unit winners, all within the book bound. After 64 matches, the remaining eligible size still covers the final unit, so neither settlement nor another match is permitted under that cap. Keep the per-call iteration limit separate from the lifetime allowance. With greedy full-candidate matching, opens paused and no candidate splitting except the final match, at most 127 counterparties can be needed from the initial book; reserving 128 quote wei is a conservative alternative to reducing the position limit.

`PositionBook.remove` swaps the last account into the removed index. A persisted numeric cursor into that mutable array can skip an unvisited account even when a different transaction removes the earlier index. Completion needs stable enumeration, such as captured addresses with current position checks. Eligibility totals accumulated across transactions cannot authorize settlement: closes, margin additions and price changes can make them stale. Recheck current eligibility across the complete book in the settlement transaction. For small iteration limits, define progress to include advancing the scan cursor; a call examining only an ineligible account need not reduce remaining size or prove whole-book insufficiency.

Validation: all six tests in `AdlValueScheduleTest` pass. Two properties ran 10,000 inputs each, checking frozen entry/value accounting across chunkings and the scheduled-profit/top-up bound. Four vectors cover the shrinking-entry mismatch, exact-profit invariant change, realizable relief on both sides and the 64-chunk stall. Formatting and diff checks pass. These are accounting/design tests, not an implemented pending state machine or a new full-runtime CI campaign.

## Pending ADL continuation properties

The accepted design now sizes lifetime rounding allowance from the configured position cap, with 64 iterations per call. Allowance uses committed coverage first, then actual protocol reserve, and explicitly permits `AdlZeroProfit` when neither can fund a zero-profit match. Stable slots, a current whole-book insufficiency proof and cursor progress replace swap removal and any terminal deadline trigger. The spec rewrite remains separate from this test stage.

`test/unit/AdlPendingProperties.t.sol` adds three fuzz properties using persistent, test-only contracts in `test/helpers/AdlPendingHarness.sol`:

| Property | Checks |
| --- | --- |
| Actual values and relief across continuations | Random positive chunk sizes, both target sides, realizable clamps, random batches of 1–64 chunks and block gaps; immutable snapshots; every prefix and final `actual = scheduled +/- relief`; final booked loss equals budget minus relief |
| Allowance consumption | Configured caps from 2–128; source partition between coverage and reserve; a sequence of exactly profitable winners producing rounded zeros; consumption at most one wei per match and no more than funded allowance; positive paid profit or exactly one matching `AdlZeroProfit` event |
| Fallback termination | Every valid starting cursor including the end sentinel, empty slots, batches of 1–64 visits, partial and full winner closes between calls, and refreshed eligibility including positions behind the cursor; no movement of other slots; current insufficiency proof; match/scan/proof progress on every call; conservation of matched, externally closed and remaining size |

The arithmetic oracle carries quotient remainders incrementally, independently of the harness's prefix-subtraction schedule. Assertions run after every continuation, including snapshot immutability and reserved-allowance conservation. The allowance fixtures exercise both sides with `count - 1` booked-zero profits, so underfunded runs consume their allowance and exercise the event fallback rather than merely generating profitable matches that never need dust.

Reservation formulas in the tests make the source split explicit: `rC = min(C, cap)`, `rReserve = min(reserve, cap - rC)`, funded allowance `= rC + rReserve`, and paired-loss coverage `= C - rC`. Accordingly the paired-loss budget is `M_after_pen + C - rC`; the shorthand `M_after_pen + C - R` applies when all of `R` is taken from `C`. Reserve-funded allowance does not debit the loser's margin. Paid profit is at least one wei except for the explicitly emitted exhausted-allowance fallback; booked profit remains nonnegative.

Fallback fuzzing allows up to `cap` external mutations per trace, including repeated partial closes. Each mutation may reclassify the remaining slots to model changed realizable eligibility. After the last mutation, a full cyclic pass of at most `cap` visits suffices to complete or prove insufficiency. The trace asserts this bound after each mutation and an aggregate finite-call bound. Four deterministic regressions cover end-cursor wraparound with holes, fresh insufficiency after a full close, a newly eligible winner behind the cursor, and reduced eligible size after a partial close. This does not claim termination under an infinite stream of external eligibility changes.

Scope: these contracts model the accepted design. They do not implement or invoke production pending ADL, stable-slot allocation/free-list reuse, price-derived eligibility, vault reservations, funding freezes or token transfers. The existing runtime still uses the earlier ADL matcher and swap-and-pop book. Port these assertions to the actual pending runtime when it is integrated; model success is not evidence that the production paths already implement the new decisions.

Verification command: `forge test --match-contract AdlPendingPropertiesTest --fuzz-runs 10000`. All seven tests pass: three properties at 10,000 inputs each and four deterministic regressions. Formatting and diff checks pass. No production contracts or ABIs changed, and no new full-runtime CI campaign is claimed.

## ADL spec reconciliation

The consolidated ADL specification now records fixed entry/value schedules, actual coverage reservations, funded rounding allowance, frozen funding, stable slots and permissionless continuations. Settlement requires a fresh complete-book insufficiency proof; the pending window only enables fallback enumeration. Its state, interfaces, parameters and required invariants are marked as the runtime integration target.

The source split is explicit throughout: `rC = min(C, R)`, `rReserve = min(reserve, R - rC)`, allowance `rC + rReserve`, and paired-loss budget `M + C - rC`. The rewrite's unconditional `M + C - R` would deduct reserve-funded allowance from the loser's budget. The spec also records signed selected collateral, coverage replaced by added margin, pro-rata realizable bounds, zero-collateral ranking and the `AdlZeroProfit` exception.

Reconciliation retained the established signed collateral, six-decimal token scaling, funding-rounding identity, status discriminants, terminal capital waterfall and cash-backing deployment gate. The reservation appears exactly once in all three cash equations. The new model coverage does not imply that production pending custody, freezes or continuation entry points are implemented.

Verification: `forge test --match-contract 'Adl(ValueSchedule|PendingProperties)Test' --fuzz-runs 10000` passed all 13 tests, including five fuzz properties at 10,000 inputs each. `git diff --check` passed. This stage changes documentation only; runtime contracts and exported ABIs are unchanged.

## Pending ADL custody and stable-slot stage

The vault now exposes per-position reservations split into loss coverage, coverage-funded rounding and reserve-funded rounding. Reserving moves actual insurance/capped-backstop balances and consumes the daily backstop window once. Coverage consumption credits locked collateral; later relief can reverse only previously consumed coverage. Margin-replacement returns cannot spend allowance. Each top-up transfers exactly one quote wei to the winner's free balance. On release, unused coverage/backstop and its allowance return to local insurance; unused reserve-funded allowance returns to protocol reserve. Even a zero-cash active reservation must be released before terminal finalization. The append-only vault fields preserve the preceding storage layout.

Position enumeration now uses stable lifetime slots and a free list. `positionAccounts` pages contain zero-address holes; `positionCount` counts live positions. Atomic settlement takes a compact snapshot in ascending slot order. Existing trading invariants independently count occupied slots and reject duplicates.

Verification: 23 selected tests passed, including eight reservation tests, three book tests, eight existing matcher tests and three terminal tests; both selected fuzz properties ran 10,000 inputs. The trading invariant passed 256 sequences at depth 50 (12,800 calls, zero reverts). Cash checks include the actual reservations and exercise cross-market terminal isolation, source returns, exhausted allowance, replacement limits and authorization. Build/size and source-lint warning gates pass. Runtime sizes: Market 23,442 bytes, MarginVault 20,367, MarketAdl 13,110 and MarketSettlement 7,263. ABIs were regenerated. The new custody methods are not yet called by the production matcher at this stage; pending continuation/funding integration follows.

## Pending ADL runtime integration

Production matching now invokes vault reservations, fixed-denominator schedules and greedy chunks. The runtime includes immediate explicit continuations, deadline-enabled slot enumeration, nonnegative-collateral/exact-profit eligibility, one-wei payments, no interim loser refunds, margin replacement and funding freezes across multiple pendings. Full-book insufficiency is the sole terminal trigger. Added margin and realizable relief can restore provisional coverage to the reservation before resolution. A covered partial-liquidation regression fixes comparison against whole-position debt: selected collateral and PnL determine the covered amount, leaving unselected funding debt locked.

The new integration suites exercise:

- Empty/truncated lists, invalid-list rollback, owner restrictions, penalty charged once, immutable schedules and immediate continuation.
- Both loser sides, random split sizes and continuation boundaries, prefix/final value sums with relief, exact booked-loss budgets, and per-chunk nonnegative booked/positive paid profit. Runtime event checks bound total top-ups by matched chunks and funded allowance.
- Multiple pending positions, reserve-funded allowance below the global floor, Guardian pause preservation and funding checkpoints without catch-up accrual.
- Deadlines enabling fallback only, 1–64 iteration limits, holes and wraparound, and fresh insufficiency after full/partial winner closes.
- Exhausted allowance emitting `AdlZeroProfit` without touching another pending reservation. This fixture uses actual market pairing plus a registered terminal-market stub to consume unreserved global capital.
- Partial selected schedules with unselected funding debt, and negative collateral remaining liquidatable despite health above maintenance. The latter predicate fixture injects a balanced vault funding debit after actual trades to isolate the predicate; it is not an organic funding-index trace.

The fallback runtime property seeds only a valid persisted cursor through a test-only market subclass. Actual prices, winner closes, eligibility, ledger moves and terminal execution use production code. It allows up to three external winner-close mutations, checks every call’s progress/proof, and requires termination within 12 calls. Independent model properties additionally exercise arbitrary finite eligibility changes and longer random chunk/continuation schedules; neither suite claims termination under infinitely changing external state.

The full CI campaign completed 35 suites / 169 tests in about 437 seconds, including all four 500,000-call invariant campaigns with zero reverts. After explicit-initialization cleanup, a final full-suite run passed all 169 tests in about 27 seconds, repeating all 20 fuzz properties at 10,000 inputs and the default 256-sequence invariant campaigns, including strengthened per-chunk payout assertions.

The liquidation invariant now independently reconciles every reservation’s loss/allowance partitions, aggregate reserved cash, net consumption, replacement, pending flags/counts, frozen schedule hashes and funding indexes. The existing curve, entry, funding, signed cash and terminal-only-deficit checks remain. Unit fuzzing covers 512-bit exact eligibility comparisons, bounded score reference calculations, saturation, and actual vault allowance isolation. Model schedule tests call production prefix arithmetic while retaining an independent quotient/remainder oracle.

Final formatting, source-lint warning, size, ABI freshness, TypeScript boundary and diff checks pass. Slither passes its medium-severity gate with five retained findings; Aderyn’s four high/five low categories have the scoped triage above. Local measured gross gas is **15,486,905** for 128-position liquidation/terminal settlement, **11,498,637** for the first 64 ranked matches and **6,889,178** for the remaining fallback matches across the 125-winner fixture. Each call stays below the 20-million local test budget.

`MarketMargin` is a new immutable linked module keeping the market below the runtime size limit. Generated ABIs include config/position tuple additions, pending views/entry points and changed ADL/terminal events. Stable-slot pages contain holes and must be consumed accordingly; SDK documentation records these interface changes. Vault storage additions remain append-only; market clones are undeployed and this is not a migration for deployed clones.

Remaining scope: no deployment, Monad fork, live oracle-adapter validation or external audit was performed. Signed cash equality with isolated funding debt or terminal protocol deficit does not prove that all free balances can be paid concurrently. The existing funding-lag cash-backing gate remains; these changes implement the agreed ADL mechanism without claiming that broader solvency proof.

## Factory, adapters and fee sweeper

This stage implements deterministic `MarketFactory` creation, Pyth Core and null adapters, and bounded batch fee allocation/sweeping. The full CI campaign passed 39 suites / 195 tests in about 335 seconds. All 22 fuzz properties ran 10,000 inputs and all four invariants ran 10,000 sequences of depth 50 with zero handler reverts. The market and vault trading/custody implementations are unchanged. Created clones must pass their existing reserve/depth/risk admission inside the same transaction that receives the seed bond.

Thirteen factory tests cover deterministic predictions, historical metadata/current creator separation, actual open/close on created clones, fixed launch caps, duplicate symbol/feed and mode rejection, atomic rollback of clone/registry/bond on invalid depth, external creation with a paid pull update, delayed original-lister refunds, governor-only slashing and both immutable destination choices, partial slash allocation, adapter/implementation delays and Guardian cancellation, original-clone persistence across implementation replacement, reserve-budget admission failure, oracle/token callback rejection and transfer-tax rollback. The escrow property fuzzes 1–8 feeds with interleaved refunds/slashes and allocation, independently checking factory cash against refundable plus slashed escrow after every step.

Seven adapter tests cover null-source restrictions, known normalization/confidence vectors, maximum/minimum representable prices, future/zero/negative observations, stale cached reads, timestamp-to-block ceiling, young-chain underflow rejection, exact fee forwarding, malformed/empty-array updates, constructor bounds and recursive provider calls. Confidence fuzzing checks that the reported width never rounds below its rational value except for explicit saturation. Two market integration tests use the production adapter with the ABI-compatible mock provider to cover paid opens, the 100-bps confidence boundary, stale-open rejection, stale closes, degradation and fresh recovery. The mock accepts test encodings; it does not validate signatures or reproduce a live Pyth deployment.

Four fee-sweeper tests cover real trading fees across two market clones, token dust, partial deficit repayment/refill without rollback, all-market allocation before treasury claims, per-market queue budgets, malformed/duplicate/unregistered batches and signed vault cash equality. Synthetic terminal stubs create controlled deficit boundaries for batch-allocation tests; production terminal valuation remains covered by the separate runtime suites.

Static review keeps the reentrancy suppression scoped to the factory’s guarded creation helper; callback tests verify that token/oracle entry cannot mutate the registries recursively. Ignored oracle-return annotations cover the null-kind check and the preliminary paid update whose cached price the actual market validates during initialization. Sweeper loop annotations describe the fixed vault target, maximum 32 markets and per-market queue bounds. NullAdapter’s payable interface rejects every nonzero value. No detector is disabled project-wide. Existing Aderyn high categories retain their documented explanations; its new native-value instances are covered by forwarding/rejection tests.

Formatting, source-lint warning, size, diff, ABI freshness and strict TypeScript method/overload checks pass. The 15 ABI exports include all four new concrete contracts plus the smaller factory interface. Runtime sizes are MarketFactory **13,091 bytes**, PythAdapter **2,897**, FeeSweeper **2,066** and NullAdapter **308**; the existing Market remains **23,354**. Slither passes the medium-severity gate with the 10 retained findings summarized above; Aderyn retains four high/five low categories after modifier-order cleanup.

Deployment choices remain explicit: slash destination, reviewed provider and implementation addresses, registrar authorization, adapter approval, initial reserve funding, and timing parameters. New adapters/implementations are delayed one day; the original factory trust root and slash destination are constructor settings. Backstop-directed slash allocation observes the deposit cap; reserve-directed allocation obeys bounded deficit repayment and bypasses that cap. Revocation is a separate successful state change when later allocation is blocked.

No deployment or live signed-update Monad fork was performed. Factory creation and local ABI compatibility do not establish target-chain gas/timing behavior, oracle availability, or the independent funding-lag cash-backing guarantee. Exact remaining risk views, resolver settlement/seed-bond return, and transaction-sending SDK/keeper/indexer work remain.

## Payer funding-capacity preparation

This stage adds a capped funding arithmetic entry point and an indexed, bounded minimum heap. It does not connect them to market state or retire reserve admission. Existing callers retain unrestricted accrual. Integration awaits decisions on protected trading collateral and recovery of a capped but healthy payer; see the corresponding section in the implementation notes.

`FundingCapacityMathTest` checks a million-block clamp with no later catch-up, zero headroom stopping both indexes, and a requested increment whose elapsed multiplication would overflow without early clamping. Its fuzz property varies both paying sides, eight unequal payer sizes and capacities, receiver size and time gaps. An independent integer-division cap calculation bounds every rounded payer debit; receivers settle first and the exact weighted funding/surplus identity is reconciled. This is a funding primitive test, not the requested shared-vault cash-backing proof.

`FundingCapacityHeapTest` covers signed extremes, ties, root replacement, empty/absent removal, full 128-entry admission, rejected overflow, repeated updates without growth, removal and reuse. Sequence fuzzing compares the minimum to a full scan after every insertion, update or removal and checks all mapping indexes and parent ordering. Mutation kind uses bits separate from slot selection so slots are not restricted to insertion-only or removal-only behavior. No production freeze or binding-position transition is claimed.

`FundingCapacityProposalTest` uses a test-only direct advance to the proposed cap; the elapsed-time and freeze control paths are not implemented by that probe. Two regressions then use production health, collateral, quote, close and withdrawal paths:

- A profitable binding payer retains exactly maintenance after its proposed funding debit and remains healthy under the existing predicate.
- A 26-position book, admitted under normal launch limits, lets a receiver settle and withdraw before the capped short. The short's entry is 1,760.173676727832441167 USDC, maintenance is 44.004341918195811030, and index rounding retains an additional six quote wei. Other shorts leave through ordinary closes. The target's resulting trading PnL is -81.020539843823830458 USDC; its close reduces insurance by 38.047266686908146935 USDC net of insurance's exit-fee share. No liquidations are called. This demonstrates reuse of trading-loss collateral by the proposed funding capacity. It does not claim a vault cash shortfall: insurance covers this trace and the signed cash/curve identities pass.

Verification for the preparation commit: **42 suites / 203 tests passed** in the default profile, including four 256 × 50 invariant campaigns. Both new fuzz properties separately passed 10,000 runs; the final heap campaign uses independent mutation/slot bits. Formatting, source-lint warning, diff and 15-export ABI freshness checks pass. The subsequent decision is to integrate protected curve-loss collateral and an explicit funding-capacity liquidation trigger; the preparation commit alone does not enable them.

## Payer funding-capacity runtime integration

Production accrual now clamps against bounded, indexed heaps with one live entry per position. Protected collateral includes worst-case curve loss, maintenance on entry notional and the worst-case exit fee. Initial margin also covers this amount. Settlement rejects a positive funding debit above the payer's own capacity before moving vault balances. Funding never obtains coverage from insurance, the backstop or protocol reserve. The heap deliberately removes and updates entries directly instead of retaining stale entries through lazy deletion.

Reaching the cap latches the binding position and freezes both side indexes. Unrelated touches, time passage and rate reversal cannot release that latch; a touch on the binding position must remove it or create usable index headroom. Checkpointing discards frozen elapsed time, so resumption never catches up. Capacity exhaustion is an explicit liquidation predicate even when trading profit keeps health above maintenance. A position opened exactly at its protected floor can have zero funding headroom and bind immediately when its side owes funding. Keepers or added margin are therefore necessary for continued accrual in such a book. Tiny partial closes also reject if fee rounding would consume the remaining exposure's curve-loss/exit-fee protection; full closure remains available.

Reserve admission no longer reserves eight funding periods per market. `reserveFloor()` is a fixed 10,000 USDC; new market funding budgets are zero, and opens/admission still require the floor to be funded and deficits cleared. The obsolete `RESERVE_BLOCKS` getter is removed. Existing budget storage remains in place for layout compatibility. Market clones remain undeployed; these changes do not provide a migration for existing clones. The SDK ABI and spec describe the new views, freeze events and liquidation predicate. Administrative/oracle maintenance moves into the immutable linked `MarketMaintenance` library to retain runtime-size headroom, with the original guarded Market entry points preserved.

Six integration tests cover both payer sides, long outages, receiver-first cash withdrawal, freeze ownership, rate reversal, sub-index-unit margin additions, ordinary margin/partial-close updates, slot reuse, explicit cap liquidation, a full 128-position heap, and repeated one-base-wei closes. The earlier 26-position maintenance-only counterexample now asserts that production rejects the obsolete excessive debit; its independent curve calculation retains the demonstration that maintenance alone cannot fund both funding and eventual trading losses.

The new `FundingBackingInvariantTest` uses two production oracle-less markets sharing one real-token vault, four traders, actual fee/referral claims and withdrawals, and no liquidations, injected debt, recapitalization or later deposits. It checks after every handler call:

- Token cash covers free balances, referral and creator claims, and positive post-funding collateral above protected collateral. Locked exposure remains subject to trading outcomes; this assertion does not label every nominal locked balance immediately withdrawable.
- Every positive unsettled funding debit fits that payer's capacity, effective collateral remains nonnegative, and reserve/backstop/deficit balances never supply funding.
- Both heap minima equal an independently recomputed full-book minimum, including address tie-breaking. An untouched binding position cannot lose its latch; both indexes stay fixed while frozen.
- Exact signed cash, curve and funding-surplus identities hold. Each ordinary close increases insurance by exactly its fee share, so fees cannot hide a coverage draw.

Every invariant sequence ends by closing receivers first, withdrawing their full available token amounts, then closing payers and withdrawing the remainder. Withdrawal amounts are never reduced to available vault cash. Final positions, clearing and funding pools are zero. A deterministic regression clamps both markets in the same block after a 100-million-block gap and completes the same receiver-first unwind. These are bounded executable properties, not a formal proof over every protocol state or a claim that terminal deficits are cash-backed.

Legacy ADL, terminal and negative-collateral tests now explicitly use `DebtShockFixture`, which injects the old unrestricted funding debits through a test-only subclass. This preserves recovery/waterfall coverage for legacy debt without claiming the new production clamp can organically create those debts. The liquidation invariant uses that fixture; the new backing invariant never does.

Verification: the full CI campaign passed **44 suites / 211 tests** in **328.61 seconds**, with **24 fuzz properties at at least 10,000 inputs each** and **five 10,000 × 50 invariant campaigns (2,500,000 handler calls), zero reverts**. After strengthening the insurance assertion to account for the exact exit-fee share, the backing suite passed another 500,000-call campaign and its deterministic regression in 314.06 seconds. Formatting, source lint, runtime sizes, diff, all 15 ABI exports and strict TypeScript boundary checks pass. Slither passes its medium threshold with the ten findings listed above; Aderyn's additional heap-memory report is triaged above. New Slither annotations cover direct tuple forwards and guarded maintenance fee/creator event paths only.

| Local scenario | Gross execution gas | Gate |
| --- | ---: | ---: |
| Funding clamp with 128 positions | 192,337 | < 500,000 |
| 128-position liquidation and terminal settlement | 18,760,836 | < 20,000,000 |
| 128-position book, first 64 ranked ADL matches | 16,864,279 | < 20,000,000 |
| Remaining fallback matches in the same 125-winner fixture | 8,474,457 | < 20,000,000 |

These measured `gasleft()` differences cover local calls, excluding setup, transaction intrinsic gas and real oracle-update costs. Settlement/ADL fixtures use explicit legacy debt. They are not charged Monad transaction gas or universal worst-case bounds. The live integration stage awaits the reviewed Pyth provider/feed IDs and access token, archive RPC with fork block, native USDC address, and funded deployer/role addresses. Fork and testnet reports must record estimated gas, submitted gas limit and charged gas/fees separately. No deployment, live signed-update fork or target-chain measurement was performed in this stage.

## Initial Monad fork integration

Four opt-in tests pass against Monad mainnet block **110547446** (October 4, 2026, 19:15:58 UTC): native contract/USDC metadata, legacy cached-equity normalization and age, the upgraded Pyth Core interface and missing cached feed state, and real native-USDC reserve/deposit/withdrawal calls through a locally deployed production vault. Test balances alone are seeded locally; no public transaction is broadcast. The configured RPC also serves a historical USDC state read 100,000 blocks earlier. The runner validates the pinned block hash before creating the fork and redacts credentials from saved Forge output.

Pyth's upgraded address table identifies mainnet Core as `0xB754BA51E3861Ac0Cb67f73CD046dE790A36508d`; the older Monad registry still identifies `0x2880aB155794e7179c9eE2e38200202908C17B43`. Both have code at the pinned block. A code/interface check alone does not establish signed-payload compatibility. Circle's native-USDC address has six decimals and passes actual fork transfer calls. Full sources, reproduction commands and measurement scope are in [Monad integration](monad-integration.md).

The ordinary Pyth regression run passes **nine tests**, including its confidence property at 1,024 inputs, with the fork suite correctly skipped from `setUp` unless explicitly enabled. Formatting, Python compilation, diff and ABI freshness checks pass. An offline authenticated-capture branch check verifies the fixed Pyth destination, Bearer headers, confidence ceiling, stale-data gate, later block capture and omission of the key from output. A file scan confirms that configured credentials are absent from reports and integration files. Production contracts and ABIs are unchanged, so the full funding invariant campaign was not repeated.

The API key was absent and public metadata requests were rejected or failed to connect. Consequently feed-registry verification, authenticated weekend freshness, signed-update execution and worst-case gas with real updates remain pending. Cached on-chain age is not evidence about live Hermes publication. No Index/US primary choice was activated; different primary/secondary IDs also need explicit mapping because the current market passes one ID to both adapters. Local fork custody gas is recorded separately from future RPC estimates, submitted limits and charged testnet fees.

## Authenticated Monad signed updates and recovery gas

The supplied API key authenticates successfully. Giving requests the application identifier `pripo-integration/1.0` resolves the default Python client-signature rejection, and all ten equity IDs match registry metadata. Requests are now isolated per feed so a denied Index does not discard an entitled regular equity update. The current grant serves BTC and TSLA US; the four other US equities are denied and all five Index feeds require `pyth-indices`. No denied feed is retried through another identity or endpoint.

At the October 4 Sunday capture, TSLA's price timestamp is **2026-10-02 23:59:59 UTC**, age **164,027 seconds**, confidence **1 bp**. Its proof availability is recent, but its price remains stale. BTC has age zero and confidence 2 bps. Production `PythAdapter` verifies BTC against the upgraded Monad provider, and the provider separately verifies TSLA before the adapter rejects its age. Tampered payload and excess native-fee rejection, stale replay, scaling, confidence, exact fee handling and adapter balance are tested. Both captured provider update fees are zero; live transaction gas is separate.

The final fork campaign passes **five suites / 12 tests** in **53.10 seconds**. Initial reads use block **110574795**; signed execution uses **110574837**, with both hashes checked and no backdating to make data fresh. Native-USDC production-market tests exercise signed opens, closes, claims, withdrawals, exact custody, degradation, zero funding and continued exits. Two 128-position fixtures use balanced test-only legacy-debt injections with real native USDC and signed BTC updates to reach terminal/ADL recovery; they do not claim production capped funding creates that debt. Final custody identities, pending cleanup, exposure removal and zero deficit are checked.

Measured local gross gas is **16,883,746** for terminal liquidation, **16,895,202** for the first 64 ranked ADL matches and **8,411,843** for fallback completion. Separately, Monad RPC estimates real provider updates at **175,853** gas for BTC and **209,965** for TSLA. These RPC estimates cover the provider only; Foundry fork execution is not a substitute for Monad-native estimation of the locally deployed protocol or live charged gas. Full measurement scope and commands are in [Monad integration](monad-integration.md).

The standard oracle regression selection passes **nine tests**, including confidence fuzzing at 1,024 inputs, and skips all five fork suites when not enabled. Four offline Python tests cover explicit client identity, rejected redirects, redacted error classification, price-time freshness, confidence ceiling and preservation of entitled captures despite other denials. Build/runtime sizes, formatting, Python tests/compilation, diff and 15-export ABI checks pass. Credential scans pass for reports and integration files. Production contracts and ABIs are unchanged; the full funding invariant campaign was not repeated. No live transaction, deployment, charged-fee measurement or equity-primary decision was made.

## Factory creation and escrow on the Monad fork

The October 5 follow-up adds **six passing factory tests** at signed-update block **110731422**, with adapter approval scheduled at block **110131422**. Their real timestamps differ by **181,260 seconds**. Early activation rejects; permissionless activation succeeds after the delay. The harness persists only local protocol deployments across forks, retaining actual Pyth and USDC state at the signed capture. Preflight records the historical header and the runner revalidates its hash alongside the observation/update anchors.

The cases cover factory-created deterministic clones, fixed launch risk configuration, oracle-authoritative pricing, exact seed/listing-bond custody, native-USDC trading and withdrawal, feed uniqueness, rollback and retry after invalid depth, reserve-floor admission, invalid signature/fee/staleness rejection, delayed listing refunds to the original lister, and batched slashed-bond allocation to reserve. Creation measures **1,112,137 local gross gas**, including test caller setup, with no live transaction.

The original **12 fork tests passed again** on the new capture. After correcting a Foundry-reserved test-name prefix, the isolated factory suite passed **6/6 in 4.33 seconds**: **18 passing fork cases across the two runs**. The standard factory suite passes **13 tests**, including 1,024 escrow fuzz inputs, and the new fork suite skips correctly without opt-in. Five offline tooling tests pass, including the exact one-day historical-anchor boundary. Formatting, Python compilation, diff and all 15 ABI checks pass; production contracts and ABIs are unchanged.

The authenticated follow-up still denies the four other regular equities and every Index feed; TSLA US is fresh at its Monday capture with 3 bps confidence. The prior Sunday staleness result remains valid. Feed selection and testnet charged fees remain pending.

## Exact capacity and liquidation-price views

`Market` now implements `maxOpenable`, `liquidationPrice` and tagged `liquidationPriceInfo`. Runtime/core/planned JSON ABIs and SDK constants are regenerated. The new code is read-only; trading, liquidation, funding, custody and storage layout are unchanged. The spec and SDK notes define additional owner capacity, exact fee/funding treatment, inclusive index thresholds, nearest adverse reachable TWAP crossings, and the reasons a scalar zero must not be interpreted as safe.

Twelve new checks cover brute-force comparison against every size in small rounded books, both index boundaries and their adjacent wei, exhaustive reachable TWAP-price comparisons, transaction execution at maximum capacity and rejection of the next wei, real short flow restoring an exceeded long quote cap, first-open book limits versus increases, pending/pause/terminal/vault gates, funding binding visible before checkpointing, and negative-collateral/no-crossing diagnostics. Non-price recovery tags use explicit synthetic test state; the backing invariants continue to use production transitions.

The full CI campaign completed **222 passing tests**, all five invariant suites at **500,000 calls each with zero handler reverts**, and one failing new fuzz fixture. The trace identified an unintended `withdraw(0)` when the fixture retained its whole free balance. After fixing that fixture branch, all **12 risk-view checks passed**, with the four new fuzz properties at **10,000 runs each**, in **29.38 seconds**. Together these runs validate **223 tests and 28 fuzz properties**. Six network-only fork suites skip without opt-in; this stage did not repeat the historical fork captures.

Extreme launch-price capacity queries measured **1,697,371 / 1,748,339** local gross gas at `2e14` WAD price and **859,736 / 873,892** at `1e28`, for long/short respectively. The regression limit is five million; interval count is not given a universal gas bound. The fixed stack bounds search depth while retaining exact handling of rounding gaps. Runtime sizes pass: **Market 21,526 bytes**, **MarketLens 13,150 bytes**. Formatting, warning-level lint, diff, all 15 ABI checks and five offline Python tests pass.

## Deployment tooling and complete fork rehearsal

The deployment script records **19 creations**, with an atomically initialized vault proxy, final Governor/Guardian/Treasury roles, both adapters, backstop, sweeper, factory and 11 linked libraries. The separate Governor script has no library link references. Its setup is resumable without resetting a pending approval deadline. The manifest records all runtime hashes, validates core address bindings and includes the three ordered zero-value Governor calls for multisig execution.

Four passing local regressions cover initializer locking and final roles; unauthorized deployer actions; partial Governor setup and retry; real approval boundaries; wrong chain, dependencies, decimals, timing and roles; conflicting backstop rejection; manifest round-trip, raw Governor calldata, the actual configuration/activation entry points, and changed-runtime rejection. Seven offline Python tests pass, including incomplete/substituted/receipted creation-plan rejection and redaction of both RPC credentials and the Pyth token.

The complete lifecycle regression passes against actual native USDC and Pyth on the two pinned Monad blocks described in the [deployment runbook](deployment.md). The standalone `forge script` simulation independently records all 19 creations and **44,622,346 gas** of simulated transaction limits, including the default multiplier; the largest limit is **6,182,954** for Market. These are Foundry EVM estimates. No public transaction, submitted gas limit or charged fee is claimed.

Runtime-size, formatting, source-lint warning, diff and all 15 ABI freshness gates pass. Slither's medium-severity gate passes with **11 retained findings**: five timestamp, one assembly and five complexity findings. Two liquidation-view tuple warnings received narrow comments: the scalar intentionally omits tags, while the tagged view directly forwards all components. Aderyn retains its five high/five low categories, with the existing triage above. This stage makes no executable protocol or ABI changes; it does not repeat the previous 2.5-million-call invariant campaign. Resolver completion, live testnet measurements and final mainnet review remain pending.
