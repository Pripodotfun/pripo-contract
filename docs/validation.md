# Foundation validation

Validation covers the shared interfaces and math libraries. The funding test harness uses synthetic accounting; USDC vault integration and market liquidation are separate milestones.

## Reproduce

```sh
make build
make ci
make analyze
```

The CI profile runs each fuzz property 10,000 times and the funding invariant 10,000 times at depth 50. `fail_on_revert = true` prevents the handler from silently discarding reverted operations. Its end-of-run check closes every synthetic position, sweeps the remaining surplus, and requires zero pending funding and zero funding pool.

## Static analysis

| Tool | Version | Result |
| --- | --- | --- |
| Forge source lint | 1.5.1 | No warnings in `src/` |
| Slither | 0.11.5 | 15 contracts analyzed, 101 detectors, zero findings after cleanup |
| Aderyn | 0.1.9 | 12 project source files, 63 detectors; one high category and four low categories, reviewed below |

The Aderyn command explicitly sets `FOUNDRY_EVM_VERSION=cancun` to match the project. This installed version otherwise fails while parsing a `prague` default. Dependency/test path filters use `lib/` and `test/`, including the slash, so they do not accidentally exclude `src/libraries/`.

### Aderyn triage

- **Unprotected initializer, high:** false positive on `RiskMath.initialMargin`. This is an `internal pure` calculation returning a number. It writes no storage, performs no initialization, and has no external entry point. There is no initializer authorization to add.
- **Event indexing, low:** the events follow the spec's indexed market/user identifiers. Numeric amounts remain in event data. Adding indexed fields would alter the public event surface without serving the specified indexing needs.
- **Large numeric literal, low:** `10_000` denotes the basis-point denominator. This spelling is intentional.
- **Internal functions called once, low:** these are reusable library primitives; the current runtime integration has not yet been added. The optimizer can inline internal functions.
- **Unused custom errors, low:** the six trading errors are part of the exported spec ABI and will be used by vault/market implementations.

Slither initially flagged an implicit zero initialization and a divide-then-multiply pattern in sweep accounting. The search lower bound now initializes explicitly. The sweep now removes the fractional remainder before dividing to quote WAD, preserving the same accounting result without the flagged expression. No detector suppressions were added for these findings.
