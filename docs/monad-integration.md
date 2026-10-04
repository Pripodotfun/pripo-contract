# Monad integration

## Verified on October 4, 2026

The configured `ALCHEMY_MONAD_RPC` responds as Monad mainnet, chain ID **143**. The initial fork is pinned to block **110547446**, timestamp **2026-10-04 19:15:58 UTC**, hash recorded in the local preflight report. An additional native-USDC state read at block **110447446** succeeds. This establishes historical access for the tested blocks, not unlimited archive retention.

| Contract | Address | Evidence |
| --- | --- | --- |
| Upgraded Pyth Core | `0xB754BA51E3861Ac0Cb67f73CD046dE790A36508d` | [Pyth's upgraded address table](https://docs.pyth.network/price-feeds/core/upgrade/contracts), deployed code and interface calls at the pinned block |
| Older Pyth Core endpoint | `0x2880aB155794e7179c9eE2e38200202908C17B43` | [Monad's protocol registry](https://github.com/monad-crypto/protocols/blob/main/mainnet/pyth.jsonc), deployed code and cached equity reads |
| Native USDC | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` | [Circle's contract list](https://developers.circle.com/stablecoins/usdc-contract-addresses), linked [explorer address](https://monadvision.com/token/0x754704Bc059F8C67012fEd69BC8A327a5aafb603), on-chain metadata and local fork transfers |

Pyth's older EVM page no longer includes a Monad row in the fetched version. Its upgraded table lists separate mainnet and testnet Core addresses. Do not infer that both networks use the older endpoint. The mainnet manifest records the upgraded candidate and the older endpoint separately; neither address has yet passed signed-update verification in this repository. Provider code presence and an empty update-fee query establish only part of ABI compatibility.

The USDC token reports **6 decimals**, symbol **USDC**, and name **USDC**. Four fork tests pass: contract/token checks, preservation of legacy cached-price age/confidence, upgraded-provider cached-state checks, and reserve funding plus deposit/withdrawal through a locally deployed production vault. Only test-account token balances are seeded with `deal`; the token implementation and transfers are real forked USDC. No live transaction is submitted.

## Equity observations and primary selection

The ten supplied US/Index IDs are stored as **candidates** in `config/monad-mainnet.json`. Each is validated as 32 bytes. Independent registry verification is still pending: metadata requests to the documented Hermes service returned HTTP 403, with one connection failure, from this environment.

At the pinned Sunday block, all ten candidate reads on the upgraded provider revert with `PriceFeedNotFound`. The older provider returns cached US prices for all five tickers and reverts for each Index query. Its cached US observations are stale. These are on-chain cache observations: an unpushed feed can have live signed data in Hermes despite missing or stale cached state.

No primary/secondary choice has been activated. `PYTH_API_KEY` was absent during this run. The authenticated latest-price check must compare publish timestamps and conservatively rounded confidence, and repeated observations must demonstrate continued off-hours publication. A `24/7` description or `is_open` metadata alone does not establish freshness or eligibility under the protocol's age/confidence gates. One weekend sample is also insufficient evidence for uninterrupted future availability.

There is an additional implementation dependency: `MarketConfig` currently supplies **one feed ID to both adapters**. Selecting `Equity.Index.X/USD` as primary and `Equity.US.X/USD` as secondary requires explicit mapping in a reviewed adapter or separate source/feed configuration. Merely setting two `PythAdapter` addresses would query the same feed twice. Freshness-driven feed selection does not currently change exchange-hours policy or enable weekend funding automatically.

## Reproduce

Put credentials in the ignored `.env` file, using the names in `.env.example`. Do not commit them.

```sh
make monad-preflight
make monad-fork

# To reproduce the initial historical snapshot:
python3 scripts/monad_preflight.py --block 110547446
make monad-fork
```

The preflight uses only read-only RPC methods. It records block number/hash/time, code fingerprints, native-USDC decimals, historical state access, candidate metadata and cached prices in `reports/monad/preflight.json`. With a key, it also fetches all ten latest signed updates, their parsed prices and per-feed age/confidence measurements, plus a later block for future signed-update verification. The key is sent as a Bearer header to the documented [Hermes endpoint](https://docs.pyth.network/price-feeds/core/upgrade/preparing). Redirects are rejected; credentials and remote error bodies are omitted from diagnostics.

The runner rechecks the pinned block hash, enables the `monad` Foundry profile, and saves redacted output in `reports/monad/fork.log`. Reports and credentials are ignored by Git. Standard tests skip the four opt-in fork cases and need no network. The fork suite currently tests cached reads and USDC custody; capturing a signed payload does not by itself test its verification or market execution.

## Gas and remaining gates

The initial native-USDC vault call measurements were **37,013 gross execution gas** for deposit and **29,357** for withdrawal. They are `gasleft()` differences with local test setup and warming, excluding transaction intrinsic gas. They are neither RPC estimates nor charged Monad gas, and are not launch limits.

[Monad charges transaction gas limits](https://docs.monad.xyz/developer-essentials/gas-pricing). The execution report must keep these fields separate:

| Measurement | Current status |
| --- | --- |
| Local EVM execution gas | Local worst-case suites plus the fork custody calls above |
| RPC `eth_estimateGas` with actual signed updates | Pending authenticated payloads and executable scenarios |
| Submitted transaction gas limit | Pending funded testnet execution |
| Receipt gas, effective gas price and charged fee/balance delta | Pending funded testnet execution |

Next gates are authenticated weekend US/Index observations; signed-update verification against the upgraded provider; ordinary trading, degraded recovery and worst-case liquidation/ADL/settlement with real updates; and remeasurement on Monad testnet. Live execution still needs its funded deployer and role addresses. The 10,000-USDC launch reserve remains a separate funding requirement. No deployment, live charged-fee measurement or primary-feed decision is claimed by this stage.
