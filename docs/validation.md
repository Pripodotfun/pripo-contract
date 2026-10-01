# Contract validation

The October 1 ADL redistribution stage passes **133 tests** under the full CI profile: ten fuzz properties at 10,000 runs and four invariant suites at 10,000 runs/depth 50, totaling **2,000,000 handler calls with zero reverts**. The reproduced one-base-wei ADL allocation failure now completes through paired closes. Validation uses a proxy vault, immutable market clones and six-decimal mock USDC with actual ERC-20 transfers. It covers whole-book funding/PnL/haircuts, signed clearing, terminal capital and deficit accounting as well as the new allocation logic. Provably indivisible dust, general allocation liveness and funding-lag cash backing remain deployment gates.

## Reproduce

```sh
make build
make ci
make analyze
```

The CI profile runs each fuzz property 10,000 times and each invariant 10,000 times at depth 50. `fail_on_revert = true` prevents the handlers from silently discarding reverted operations. The funding/trading end-of-run checks close every position and sweep the remaining funding surplus. The real-token trading suite additionally requires zero curve clearing and entry cost, with reserves restored to their seed values. The separate capital suite checks custody transitions against terminal-market stubs. The fourth suite exercises actual market liquidation, ADL and forced settlement; its scope is detailed below.

The market handler exercises opens/increases, partial/full closes, margin changes, block advances, funding sweeps, claims, deposits and withdrawals across eight traders. It recomputes signed cash equality against the token balance, entry-cost and weighted-index sums, base exposure, and the exact funding-surplus identity after every call. Opens assert impact margin and both side caps. The bounded campaign uses at most 18 base units per trader and 12,000 blocks per advance; it does not model exhausted-insurance liquidation. A separate long-idle regression exercises funding debt exceeding margin and insurance coverage on voluntary close.

On this macOS installation, sandboxed `forge test` crashes in the system proxy settings library before test execution. Tests were run outside that sandbox, without an RPC or private key. Upgrade-delay tests read the scheduled deadline from the contract instead of reusing `block.timestamp` across `vm.warp`, because the IR optimizer may cache a transaction's timestamp.

## Static analysis

| Tool | Version | Result |
| --- | --- | --- |
| Forge source lint | 1.5.1 | No warnings in `src/` |
| Slither | 0.11.5 | 51 contracts analyzed, 101 detectors; one low timestamp finding, one informational assembly finding and four informational complexity findings after scoped annotations |
| Aderyn | 0.1.9 | 27 project source files, 63 detectors; four high categories and five low categories, reviewed below |

The size gate passes: Market is 23,442 bytes, MarketTrading 6,763 bytes, MarketLiquidation 6,483 bytes, MarketAdl 13,163 bytes, MarketSettlement 7,107 bytes, MarketAccounting 9,013 bytes, MarketLens 7,810 bytes, MarginVault 17,489 bytes and InsuranceBackstop 2,793 bytes with the pinned compiler and settings. The implementation and every linked module fit within EIP-170's 24,576-byte limit; Market has 1,134 bytes of remaining headroom. ABI freshness checks and a TypeScript import/method-boundary check pass. Runtime ABIs include both liquidation overloads, settlement preflight/info and the vault's coverage/terminal custody methods. Exact remaining risk views and resolver integration remain future work.

The Aderyn command explicitly sets `FOUNDRY_EVM_VERSION=cancun` to match the project. This installed version otherwise fails while parsing a `prague` default. Dependency/test path filters use `lib/` and `test/`, including the slash, so they do not accidentally exclude `src/libraries/`.

### Aderyn triage

- **Unprotected initializer, high:** `RiskMath.initialMargin` and `MarketAccounting.initialMargin` calculate margin and do not initialize storage. `MarkTwap.initialize` is a linked Solidity library function with a storage reference and an explicit nonempty-state rejection; its market call is inside the registrar-authorized, `initializer`/`nonReentrant`-guarded initialization. Clone and implementation initialization, repeat initialization, and initialization callbacks are tested.
- **Tautological comparison, high:** `MarketAdl._before` compares scores and addresses of two different candidate instances. The analyzer identifies their common struct members as identical operands; `a.score == b.score` is not a self-comparison. Multi-candidate ordering, invalid ordering and the reverse-ordered full-book gas case exercise this comparator.
- **Unchecked return, high:** open/addMargin/removeMargin/liquidate, paired ADL and terminal execution call `settleFunding` for its state and ledger effects. Those paths need the state/ledger effects; all callers still execute the settlement and propagate reverts. Voluntary close also ignores the total returned by `coverDebt`, which emits the required per-source debt events itself. Terminal execution ignores `finalizeSettlement`'s returned amount because the vault emits sources and stores the deficit; the caller reads stored deficit for liquidation reporting.
- **Locked Ether, high:** the vault's inherited payable UUPS override rejects native value. Non-degraded external-index open/remark/liquidate forward all supplied value to the primary adapter; oracle-less calls, degraded liquidation and every close reject it. Adapter failure with value reverts atomically. Tests check fee forwarding, rejection and zero retained market balance.
- **Public visibility, low:** UUPS uses the inherited public override signature. Linked libraries are deliberately public so their code is deployed separately instead of copied into Market.
- **Repeated literals, low:** these are fixed launch parameters validated at initialization, including window lengths, funding periods and risk sets. Governance parameter changes are a later integration.
- **Event indexing, low:** the events follow the spec's indexed market/user identifiers. Numeric amounts remain in event data. Adding indexed fields would alter the public event surface without serving the specified indexing needs.
- **Large numeric literal, low:** `10_000` denotes the basis-point denominator. This spelling is intentional.
- **Internal functions called once, low:** reusable math primitives are intentionally kept as named functions. The optimizer can inline internal functions.

Slither's foundation findings for an implicit zero initialization and divide-then-multiply sweep accounting were fixed directly. Runtime annotations are limited to the reviewed nodes/functions: exact zero/enum discrimination, deliberately unused simulated state, and guarded oracle/vault calls. Every mutating market entry point, including initialization, holds `nonReentrant`; the only adapter callbacks observe the pre-trade checkpoint, and vault ledger methods do not transfer tokens; coverage calls the bound backstop controller, whose market/vault reads are static. Callback tests verify rejection during trading and bootstrap. The new whole-book loop annotations document the 128-account limit, fixed vault target and enclosing market guard. These annotations do not disable detectors project-wide and need review when affected call paths change. Slither's four complexity findings remain visible in ADL planning/eligibility/execution and liquidation dispatch; integration cases exercise their main branches, but the integer-fragment liveness gate remains open.

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
