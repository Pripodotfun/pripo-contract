# Contract validation

Validation covers the math libraries, a proxy-based vault, and immutable market clones using six-decimal mock USDC with actual token transfers. The September 28 CI run passed **65 tests**, including six fuzz properties at 10,000 runs and two invariant suites at 10,000 runs/depth 50: **1,000,000 total handler calls, zero reverts**. That campaign predates the backstop/module changes below; liquidation, ADL and resolver settlement remain separate milestones.

## Reproduce

```sh
make build
make ci
make analyze
```

The CI profile runs each fuzz property 10,000 times and each invariant 10,000 times at depth 50. `fail_on_revert = true` prevents the handlers from silently discarding reverted operations. Both end-of-run checks close every position and sweep the remaining funding surplus. The real-token suite additionally requires zero curve clearing and entry cost, with reserves restored to their seed values.

The market handler exercises opens/increases, partial/full closes, margin changes, block advances, funding sweeps, claims, deposits and withdrawals across eight traders. It recomputes signed cash equality against the token balance, entry-cost and weighted-index sums, base exposure, and the exact funding-surplus identity after every call. Opens assert impact margin and both side caps. The bounded campaign uses at most 18 base units per trader and 12,000 blocks per advance; it does not model exhausted-insurance liquidation. A separate long-idle regression exercises funding debt exceeding margin and insurance coverage on voluntary close.

On this macOS installation, sandboxed `forge test` crashes in the system proxy settings library before test execution. Tests were run outside that sandbox, without an RPC or private key. Upgrade-delay tests read the scheduled deadline from the contract instead of reusing `block.timestamp` across `vm.warp`, because the IR optimizer may cache a transaction's timestamp.

## Static analysis

| Tool | Version | Result |
| --- | --- | --- |
| Forge source lint | 1.5.1 | No warnings in `src/` |
| Slither | 0.11.5 | 42 contracts analyzed, 101 detectors; one low timestamp finding and one informational assembly finding after scoped annotations |
| Aderyn | 0.1.9 | 22 project source files, 63 detectors; three high categories and six low categories, reviewed below |

The size gate passes: Market is 21,647 bytes, MarketTrading 6,089 bytes, MarketAccounting 8,912 bytes, MarketLens 7,753 bytes, MarginVault 11,258 bytes and InsuranceBackstop 2,793 bytes with the pinned compiler and settings. Linked modules leave room for liquidation entry points within EIP-170's 24,576-byte limit. ABI freshness checks and a TypeScript import check pass; the concrete market ABI excludes the planned liquidation selector.

The Aderyn command explicitly sets `FOUNDRY_EVM_VERSION=cancun` to match the project. This installed version otherwise fails while parsing a `prague` default. Dependency/test path filters use `lib/` and `test/`, including the slash, so they do not accidentally exclude `src/libraries/`.

### Aderyn triage

- **Unprotected initializer, high:** `RiskMath.initialMargin` and `MarketAccounting.initialMargin` calculate margin and do not initialize storage. `MarkTwap.initialize` is a linked Solidity library function with a storage reference and an explicit nonempty-state rejection; its market call is inside the registrar-authorized, `initializer`/`nonReentrant`-guarded initialization. Clone and implementation initialization, repeat initialization, and initialization callbacks are tested.
- **Unchecked return, high:** open/addMargin/removeMargin call `settleFunding` for its state and ledger effects. The returned debit is needed only by close-event reporting; all callers still execute the settlement and propagate reverts.
- **Locked Ether, high:** the vault's inherited payable UUPS override rejects native value. External-index open/remark forward all supplied value to the primary adapter; oracle-less opens and every close reject it. Adapter failure with value reverts atomically. Tests check fee forwarding, rejection and zero retained market balance.
- **Public visibility, low:** UUPS uses the inherited public override signature. Linked libraries are deliberately public so their code is deployed separately instead of copied into Market.
- **Repeated literals, low:** these are fixed launch parameters validated at initialization, including window lengths, funding periods and risk sets. Governance parameter changes are a later integration.
- **Event indexing, low:** the events follow the spec's indexed market/user identifiers. Numeric amounts remain in event data. Adding indexed fields would alter the public event surface without serving the specified indexing needs.
- **Large numeric literal, low:** `10_000` denotes the basis-point denominator. This spelling is intentional.
- **Internal functions called once, low:** reusable math primitives are intentionally kept as named functions. The optimizer can inline internal functions.
- **Unused custom errors, low:** `NotLiquidatable` is reserved for the next liquidation milestone.

Slither's foundation findings for an implicit zero initialization and divide-then-multiply sweep accounting were fixed directly. Runtime annotations are limited to the reviewed nodes/functions: exact zero/enum discrimination, deliberately unused simulated state, and guarded oracle/vault calls. Every mutating market entry point, including initialization, holds `nonReentrant`; the only adapter callbacks observe the pre-trade checkpoint, and vault ledger methods do not transfer tokens or call out. Callback tests verify rejection during trading and bootstrap. These annotations do not disable detectors project-wide and need review when the affected call paths change.

## Vault stage

Ten vault tests cover custody, isolated debt, balanced funding/PnL/insurance transfers, claims and dust, referral binding, operator expiry/revocation/spending/Merkle scope, deposit caps, initialization, upgrade delay/veto/storage, callback reentrancy, and transfer-tax rejection.

Slither's added timestamp finding is the deliberate 48-hour governance delay. Aderyn additionally flags inherited payable UUPS upgrade entry points as potentially locking Ether; the override rejects nonzero `msg.value`. Its `public` visibility is required by the inherited UUPS signature. No ordinary vault operation accepts native tokens. Modifier ordering was corrected. Existing math and event/style findings remain as described above.

## Runtime stage

Integration tests cover quote/execution agreement, increases and partial-close dust, winner withdrawals before the loser closes, receiver-first funding, isolated funding debt, margin removal, launch caps, slippage, operator enforcement and atomic policy consumption, referrals and fee claims, guardian pause/resume, zero-OI reseeding, creator transfer, initialization, two-market isolation, stale/confident/broken oracles, secondary fallback, native fee forwarding, cached-price accrual, same-block TWAP manipulation, ring wrap/interpolation, and oracle callback rejection.

No Monad fork, live oracle adapter, deployment, full liquidation/waterfall test, or external audit is claimed by these results.

## Backstop and module stage

The default-profile regression suite passes **72 tests**, including all 65 prior tests and seven new backstop tests. Both invariant suites ran 256 sequences of depth 50 with zero reverts. New tests cover insurance-first coverage, per-market 20%/10% budgets, window expiry and the genesis-block boundary, no refill from repeated claims or new funding, surplus reserve retention, capped/self-liquidation penalties, locked-only debt transfers, authorization and cash equality. Market integration tests continue to exercise linked-module callbacks and native update fees.

The market refactor uses namespaced storage and fixed linked libraries. All production components remain below the runtime limit. The default campaign checks existing trading behavior; it does not validate an ADL selection algorithm or a terminal shortfall policy.

Static review of the new controller call: `coverBadDebt` is guarded and calls the governor-bound controller, whose implementation performs only static reads of the registered market and vault before updating its own budget. Registered market code remains trusted. Module oracle targets come from validated immutable configuration; supplied native value is forwarded only to that configured adapter. The corresponding analyzer annotations are scoped to these calls. Storage-pointer assembly assigns one fixed namespace; it does not accept a caller-selected slot.
