# Tenderly rehearsal: RPC and EVM chain IDs differ

Observed October 10, 2026. This report is ready to share with Tenderly; no support message has been sent.

The user subsequently selected single-account governance. A separate [active Tenderly demo](../deployments/tenderly-demo.json) now has a funded reserve and `PRIPO:DEMO`; the signature-domain issue described here remains relevant to the earlier Safe deployment.

## Environment

- Account/project: `monad-b15b6908b0/project`.
- Environment: `b1348816-5fd8-46c6-9c73-97d2e30bba56`.
- Instance: `3e0a2541-d57b-4099-a0ad-4e9ad1b4b789`.
- Virtual network: `e0d1eea6-a5da-4cb4-8e9f-ccfb773f704c`.
- Fork: Monad mainnet, network `143`, block `111799132`, hash `0x6a962ed33bce04011cdc3eeda06fdcb673d4e58e9c7ed5e3d41c5f0a176734a3`.
- Requested override: `network_configs[0].chain_config_overrides.chain_id = "999143"`.
- Returned environment metadata and `eth_chainId`: `999143`.
- Safe `getChainId()` through `eth_call`: **`1`**. Explicit transaction `chainId` values of `"0xf3ee7"` and `999143` also return `1`.
- State synchronization is disabled. USDC, Pyth Core and Safe dependency code matched pinned Monad mainnet bytecode.

The [Safe 1.4.1 implementation](https://github.com/safe-global/safe-smart-account/blob/v1.4.1/contracts/Safe.sol) reads the `CHAINID` opcode in `getChainId()` and includes it in its transaction signing domain.

## Read-only reproduction

From the contract repository with the private Admin RPC stored in ignored `.env`:

```sh
PYTHONPATH=scripts python3 - <<'PY'
from monad_preflight import load_env, rpc
endpoint = load_env()['TENDERLY_RPC']
safe = '0xfEaE61d10D2A68C4AC7282d795724119559e7Ae3'
print('RPC:', int(rpc(endpoint, 'eth_chainId', []), 16))
print('EVM:', int(rpc(endpoint, 'eth_call', [
    {'to': safe, 'data': '0x3408e470'}, 'latest'
]), 16))
PY
```

Expected: both `999143`. Observed: `999143`, then `1`. The RPC URL and API token are intentionally omitted from this report.

## Transaction evidence

Four Safes and all 19 Pripo contracts deployed successfully. Safe owners, thresholds and protocol runtime hashes were verified. The Governor rejects an empty signature list with `GS020`.

Foundry simulated the three governance calls successfully on chain `999143`. The first submitted call reverted:

- Transaction: `0xfa2e1e79322061e1b4ddaf530943353d5cd56bc55ac35df9ece93b51c88e384a`.
- Block: `111799158`; gas limit `174506`; receipt gas used `64603`.
- Governor: `0xfEaE61d10D2A68C4AC7282d795724119559e7Ae3`.
- Safe nonce remains `0`; the vault backstop remains unset. The other two governance calls were not submitted.
- Tenderly `debug_traceTransaction` shows a revert during Safe signature verification, before a call into Pripo.
- The execution trace and live Safe `getTransactionHash()` agree on hash `0xa4f4e570defe5edc1ac86d79cd364ed80bde47c115587319dcd0a3a5d105265b`.
- The first signature recovers `0xed4af8def4a2cd4892025ee14a784afdc8b23f3f` in that execution, which is not a configured owner.

The private local trace, transactions and probe results are retained under `reports/deployment/tenderly/`. Sanitized provenance, addresses and receipts are committed in [the rehearsal record](../deployments/tenderly-rehearsal.json).

## Requested resolution and recovery

Confirm the supported configuration that makes the EVM `CHAINID` opcode equal the configured virtual chain ID for a Monad fork, or correct this environment's execution configuration. The documented Admin RPC methods do not expose a chain-ID setter.

The Safe deployment tooling requires agreement between `eth_chainId` and Safe's `getChainId()` before mutations. If returning to a Safe rehearsal, resolve the mismatch, create a fresh Monad fork and rerun that workflow. The original Safe-governed vault is unfunded and its factory has no market. The later single-account demo uses separate custody and factory contracts, records both chain IDs, and performs no typed-signature governance. This issue report does not establish mainnet readiness.
