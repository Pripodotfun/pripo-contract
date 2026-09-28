# @pripo/sdk

This package currently contains generated ABI constants. `marketAbi` and `marginVaultAbi` describe the implemented runtime contracts, including operator-proof overloads, vault administration, and initialization.

```ts
import { marketAbi, marginVaultAbi } from "@pripo/sdk/abis";
```

`marketCoreAbi` and `marginVaultInterfaceAbi` are the smaller integration interfaces. `plannedMarketAbi` is the future Phase 1 interface, including methods such as liquidation and resolver wind-down that are not implemented yet. Factory, resolver, price-source and shared-error ABIs are also exported.

Exports are TypeScript source for consumption by a TypeScript-aware bundler. Regenerate them with `make abi` from the repository root, or run `npm run generate` here after a Foundry build. Transaction simulation, oracle updates, signing, and typed trading methods are the next SDK work. Operator callers should use `quoteOpenFor(user,size)` and pass a market proof when their policy requires one; expiry is denominated in blocks.
