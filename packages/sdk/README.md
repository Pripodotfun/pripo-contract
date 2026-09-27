# @pripo/sdk

The initial package contains generated ABI constants for the protocol interfaces.

```ts
import { marketAbi, marginVaultAbi } from "@pripo/sdk/abis";
```

Exports are TypeScript source for consumption by a TypeScript-aware bundler. Regenerate them with `make abi` from the repository root, or run `npm run generate` here after a Foundry build. Transaction simulation, oracle updates, signing, and typed trading methods will be added after vault/market integration.
