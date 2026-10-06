# Monad integration

## Mock collateral update — October 6

The active testnet demo uses **Pripo Mock USDC (`mUSDC`)**, with a verified 10,000-token reserve in a new vault. It reuses the original implementation/adapters and the real testnet Pyth provider. [Active addresses](../deployments/monad-testnet.json) and the [mock workflow](testnet-staging.md#mock-collateral-workflow) identify this freely minted test asset explicitly. The [native-USDC deployment](../deployments/monad-testnet-native.json) and historical real-token fork evidence below remain separate integration records.

## Staging update — October 6

Monad testnet (10143) is now the shared staging target until Tenderly access is available after submission. The configured RPC serves the official testnet USDC and upgraded Pyth Core contracts. [Testnet staging](testnet-staging.md) records the current commands and evidence. Local mainnet/testnet forks continue to cover accelerated block/time scenarios; public testnet provides real execution and fee receipts. The October 5 Tenderly choice below is historical.

## Staging update — October 5

Shared staging now uses a fresh Tenderly Virtual TestNet fork of Monad **mainnet**, with the same USDC and Pyth addresses verified below. Tenderly's live registry confirms Virtual TestNet and monitoring support for chain 143. The rehearsal uses virtual chain 999143 and fork-local Safes; no hosted fork or alert is claimed until account setup and deployment receipts exist. See the [current runbook](deployment.md) for the Tuesday–Saturday plan, alert definitions and Thursday Resolver fallback.

Historical Foundry captures below remain local regression evidence. Refork on each testing day and before the final rehearsal, and validate new signed Pyth updates against the fresh router state. Monad testnet is used only for Friday's one-hour native gas/timing measurements and optional Mera P-256 verification; testnet faucet/mock-USDC staging is removed.

## Verified on October 4, 2026 (UTC)

The configured `ALCHEMY_MONAD_RPC` responds as Monad mainnet, chain ID **143**. The initial fork is pinned to block **110547446**, timestamp **2026-10-04 19:15:58 UTC**, hash recorded in the local preflight report. An additional native-USDC state read at block **110447446** succeeds. This establishes historical access for the tested blocks, not unlimited archive retention.

| Contract | Address | Evidence |
| --- | --- | --- |
| Upgraded Pyth Core | `0xB754BA51E3861Ac0Cb67f73CD046dE790A36508d` | [Pyth's upgraded address table](https://docs.pyth.network/price-feeds/core/upgrade/contracts), deployed code and interface calls at the pinned block |
| Older Pyth Core endpoint | `0x2880aB155794e7179c9eE2e38200202908C17B43` | [Monad's protocol registry](https://github.com/monad-crypto/protocols/blob/main/mainnet/pyth.jsonc), deployed code and cached equity reads |
| Native USDC | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` | [Circle's contract list](https://developers.circle.com/stablecoins/usdc-contract-addresses), linked [explorer address](https://monadvision.com/token/0x754704Bc059F8C67012fEd69BC8A327a5aafb603), on-chain metadata and local fork transfers |

Pyth's older EVM page no longer includes a Monad row in the fetched version. Its upgraded table lists separate mainnet and testnet Core addresses. Do not infer that both networks use the older endpoint. The upgraded mainnet provider now verifies real BTC and TSLA Hermes payloads in the fork suite. The older endpoint remains a cached-read comparison; its signed-update compatibility has not been tested here.

The USDC token reports **6 decimals**, symbol **USDC**, and name **USDC**. The initial four cached-read/custody tests are retained. The expanded suite passes **12 tests**, including real signatures, tamper rejection, exact update-fee handling, stale replay rejection, production market trading and full-book recovery. The authenticated capture uses block **110574795** for initial observations and **110574837** (2026-10-04 21:33:48 UTC) for signed updates, with both hashes checked before testing. No time is backdated to make a payload fresh.

Only test-account token balances are seeded with `deal`; token code and transfers are real native USDC. Production market tests use registrar-created clones with the factory's actual launch configuration, exercise signed opens and ordinary closes, withdraw user balances, and reconcile exact custody. A separate trace advances local time to verify degradation, zero funding and continued closes with an expired real update. No live transaction is submitted.

## Equity observations and primary selection

All ten supplied US/Index IDs match the authenticated Pyth registry's expected symbols and descriptions. They remain **candidates** in `config/monad-mainnet.json` until primary selection. The initial Python default user agent was rejected by the service; requests now identify the application as `pripo-integration/1.0`, with no browser impersonation. Authentication is independent of feed entitlement.

At the pinned Sunday block, all ten candidate reads on the upgraded provider revert with `PriceFeedNotFound`. The older provider returns cached US prices for all five tickers and reverts for each Index query. Its cached US observations are stale. These are on-chain cache observations: an unpushed feed can have live signed data in Hermes despite missing or stale cached state.

The key is accepted, but only one of the ten equity candidates is currently entitled:

| Feed group | Authenticated result |
| --- | --- |
| TSLA US | Signed update captured; price published **2026-10-02 23:59:59 UTC**, age **164,027 seconds** (45.6 hours), confidence **1 bp** at capture; stale under the three-second gate |
| NVDA, AAPL, COIN and HOOD US | HTTP 403: not entitled to the requested asset/feed |
| All five Index feeds | HTTP 403: requires the **`pyth-indices`** group |
| BTC control | Signed update captured; age **0 seconds**, confidence **2 bps** at capture |

TSLA's newly available proof still contains Friday's price timestamp. The fork verifies its signature successfully and then verifies that `PythAdapter` rejects it as stale. Proof availability does not refresh an observation. BTC is a technical control, not evidence that equities publish over the weekend. The captured provider update fee is **zero native wei** for both payloads; gas remains payable on live transactions.

No primary/secondary choice has been activated. Enable the denied regular equity feeds and `pyth-indices` to finish the comparison. Repeated off-hours observations must establish publication and confidence under the existing gates. A `24/7` description or `is_open` metadata alone does not establish freshness, and an entitlement rejection says nothing about whether a feed is live.

There is an additional implementation dependency: `MarketConfig` currently supplies **one feed ID to both adapters**. Selecting `Equity.Index.X/USD` as primary and `Equity.US.X/USD` as secondary requires explicit mapping in a reviewed adapter or separate source/feed configuration. Merely setting two `PythAdapter` addresses would query the same feed twice. Freshness-driven feed selection does not currently change exchange-hours policy or enable weekend funding automatically.

## Factory verification on October 5, 2026 (UTC)

The follow-up capture pins signed updates to block **110731422**, timestamp **2026-10-05 10:43:45 UTC**. Adapter approval is scheduled at historical block **110131422**, timestamp **2026-10-03 08:22:45 UTC**; **181,260 seconds** elapse before activation. The suite rejects early activation and permits an unrelated caller to activate after the real one-day delay. Only locally deployed protocol contracts persist across these two forks.

Six new factory tests pass, bringing verified fork coverage to **18 tests**. They exercise deterministic cloning through the production factory, the actual launch configuration and signed BTC updates; the 5,000-USDC seed bond and 500-USDC listing escrow; a trader's deposit/open/close/withdrawal and exact vault custody; and atomic rollback for failed initialization, insufficient reserve, invalid signatures, incorrect update fees and stale prices. Rejected creation leaves the creator's tokens, native balance, clone address, registries and insurance unchanged, then valid creation can reuse the symbol. Listing refunds wait until maturity and pay the original lister; slashed escrow refills reserve through separate batches.

The factory-created market uses the verified oracle price despite a creator-supplied initial price of one. Its clone runtime targets the reviewed implementation, and the factory retains neither seed funds nor a vault token allowance. Measured creation cost is **1,112,137 local gross gas**, including the test caller setup; this is not a Monad RPC estimate or charged gas.

Feed permissions are unchanged: only TSLA US and the BTC control are accessible among the requested captures. TSLA US resumed publication by Monday's capture, with age zero and **3 bps** confidence. This does not establish weekend availability or provide an Index comparison. Sunday's observation remains the off-hours evidence above.

## Reproduce

Put credentials in the ignored `.env` file, using the names in `.env.example`. Do not commit them.

```sh
make monad-preflight
make monad-fork
make monad-estimate-pyth

# To reproduce the initial historical snapshot:
python3 scripts/monad_preflight.py --block 110547446
make monad-fork
```

The preflight uses only read-only RPC methods. It records block number/hash/time, code fingerprints, native-USDC decimals, historical state access, candidate metadata and cached prices in `reports/monad/preflight.json`. With a key, it attempts each equity feed separately and captures a BTC control, preserving per-feed errors rather than discarding accessible payloads when another feed is denied. Prices, signed payloads, observation times and freshness measurements accompany a later block for signed-update verification. The key is sent as a Bearer header to the documented [Hermes endpoint](https://docs.pyth.network/price-feeds/core/upgrade/preparing). Redirects are rejected; only recognized error categories are reported, without raw response bodies or credentials.

The preflight also records a `governanceFork` header 600,000 blocks before the signed capture and checks that at least one day elapsed between their actual timestamps. The factory suite schedules adapter approval on that earlier fork, carries its local deployments to the signed-update fork, and activates permissionlessly there. Pyth and USDC remain the real state at each selected block. No storage edit bypasses the approval delay, and no oracle timestamp is backdated. An unavailable historical anchor is reported explicitly and skips the factory suite.

The runner rechecks all recorded block hashes, enables the `monad` Foundry profile, and saves redacted output in `reports/monad/fork.log`. Reports and credentials are ignored by Git. Standard tests skip the opt-in fork suites and need no network. Five offline Python regression tests cover client identification/redirect rejection, safe error classification, freshness/confidence, preservation of entitled captures when others fail, and the minimum elapsed governance delay. Run them with `python3 -m unittest discover -s test/scripts`; `make ci` includes them.

## Gas and remaining gates

| Local fork scenario | Gross execution gas |
| --- | ---: |
| Native-USDC vault deposit / withdrawal | 37,013 / 29,357 |
| BTC signed update through production adapter | 92,754 |
| TSLA signed provider update | 109,024 |
| Production BTC open with a signed update | 694,486 |
| 128-position terminal liquidation with a signed update | 16,883,746 |
| 128-position first 64 ranked ADL matches with a signed update | 16,895,202 |
| Remaining fallback matches | 8,411,843 |

These are `gasleft()` differences with local test setup and warming, excluding transaction intrinsic gas. Each measured recovery call stays below the existing 20-million local budget. Recovery fixtures explicitly inject historical debt as balanced payer/receiver vault entries through a test-only subclass; production capped funding cannot create this state through unlimited accrual. Real oracle signatures, native USDC, production recovery and final cash identities are checked. This does not prove a maximum across all oracle payload sizes, price configurations or book arrangements.

[Monad charges transaction gas limits](https://docs.monad.xyz/developer-essentials/gas-pricing). The execution report must keep these fields separate:

| Measurement | Current status |
| --- | --- |
| Local EVM execution gas | Captured scenarios above; standard Foundry EVM execution of forked state |
| Monad RPC `eth_estimateGas` for signed provider updates | **BTC 175,853; TSLA 209,965**, pinned at block 110574837 |
| Submitted transaction gas limit | Pending funded testnet execution |
| Receipt gas, effective gas price and charged fee/balance delta | Pending funded testnet execution |

`make monad-estimate-pyth` uses [Alchemy's read-only gas estimator](https://www.alchemy.com/docs/chains/monad/monad-api-endpoints/eth-estimate-gas) against the actual provider. It uses an unfunded synthetic sender, no gas-price field, a 30-million simulation ceiling and the provider's exact update fee. Results are in `reports/monad/pyth-gas-estimates.json`; submitted-limit and charged-fee fields stay null because nothing was sent. These estimates cover provider updates only; they are not Monad-native estimates for the locally deployed protocol's recovery calls.

Next gates are the missing equity/Index entitlements and repeated off-hours observations; explicit primary/secondary feed mapping once selected; full protocol gas estimation on a Monad execution environment; and remeasurement with a funded deployer on Monad testnet. Live execution still needs its deployer and role addresses. The 10,000-USDC launch reserve remains a separate funding requirement. No deployment, live charged-fee measurement or primary-feed decision is claimed by this stage.
