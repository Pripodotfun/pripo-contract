# @pripo/sdk

This package currently contains generated ABI constants. `marketAbi` and `marginVaultAbi` describe the implemented runtime contracts, including operator-proof overloads, vault administration, and initialization.

```ts
import { marketAbi, marginVaultAbi } from "@pripo/sdk/abis";
```

`marketCoreAbi` and `marginVaultInterfaceAbi` are the smaller integration interfaces. `plannedMarketAbi` is the future Phase 1 interface, including methods such as `liquidationPrice`, `maxOpenable`, and resolver wind-down that are not implemented yet. `liquidate` is implemented in `marketAbi` and `marketCoreAbi`; ADL is not implemented. `insuranceBackstopAbi` and `insuranceBackstopInterfaceAbi` expose the controller. Factory, resolver, price-source and shared-error ABIs are also exported.

The vault ABI includes reserve/deficit views, `fundProtocolReserve`, `recapitalize`, WAD-denominated `contributeToDeficit`, bounded `allocateProtocolFees`, and gated treasury claims. Token contributions use raw six-decimal USDC; reserve, fee and deficit balances use WAD. Allocation accepts 1–32 queue entries per call and may leave fees awaiting a later batch. Global token contributions also have a 32-entry allocation limit and revert atomically when more processing is required. `requireOpenAllowed(market)` checks reserve admission, deficit and floor gates; quote calculations alone do not guarantee an open can execute. `finalizeSettlement` is a trusted-market custody hook; the market's whole-book settlement engine remains unimplemented.

The market exposes `positionCount()` and `positionAccounts(offset, limit)` for its bounded book of at most 256 nonempty positions. Page limits above 256 revert; removals can reorder accounts, so read all pages at the same block. Increasing an existing position does not consume another slot.

Exports are TypeScript source for consumption by a TypeScript-aware bundler. Regenerate them with `make abi` from the repository root, or run `npm run generate` here after a Foundry build. Transaction simulation, oracle updates, signing, and typed trading methods are the next SDK work. Operator callers should use `quoteOpenFor(user,size)` and pass a market proof when their policy requires one; expiry is denominated in blocks.
