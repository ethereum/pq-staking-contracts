# Site

Interactive model of the staking and request contracts. The released contract bytecode runs in
an EVM in the browser ([`@ethereumjs/evm`](https://github.com/ethereumjs/ethereumjs-monorepo),
Prague rules); the consensus layer is a simplified TypeScript model.

```sh
npm install
npm run dev     # exports the contract bytecode (needs forge), then starts Vite
npm run build   # same export, then a static build in dist/
```

Both scripts run `npm run sync-contracts`, which runs `contracts/scripts/export-bytecode.sh` and
copies `contracts/dist/bytecode.json` to `src/generated/` (git-ignored). The site therefore runs
exactly the bytecode a release from the same commit would ship.

## What is real and what is modeled

| Layer | Source | Notes |
| --- | --- | --- |
| Contracts, fees, queues, encodings, reverts | Real bytecode in the in-browser EVM | `src/chain/` |
| End of block | `SYSTEM_ADDRESS` calls to each system contract | Returned bytes are decoded and shown |
| Staking logs | `CreateStake` / `TopUp` events, read like deposit logs today | |
| Consensus layer | Model in `src/sim/consensus.ts` | Follows EIP-8413 and issue #1; delays, churn and balances simplified |
| Keys and signatures | 12 pre-generated leanXMSS demo keys (`src/keys/`, from the generator in `xmss/`) | Proofs of possession are real signatures made in the browser and verified by the registration contract; one key per stake. The PoP leaf comes from the message, so the browser rebuilds a 256-leaf subtree per signature. It also tries about 2²⁰ randomizers to find one the scheme accepts, so the hashing runs in WebAssembly ([hash-wasm](https://github.com/Daninet/hash-wasm)). A signature takes about 1 to 2 s |
| Authorization commitment | `0x01 ‖ sha256(pq_pubkey)[1:]` | Demo assumption; EIP-8413's initial version commits to a BLS key |

The chain starts with 3 migrated validators (stake IDs 0–2) so new stake IDs start at 3.

## Using it

Pick an actor at the top, open an operation on the left and press **Send**: the transaction
lands in the current block, and requests to system contracts appear as tokens in their queue.
**End block** seals the block, runs the system calls (up to the per-block maximum leaves each
queue), then the consensus layer updates the stake cards. Click a stake card to use it in the
open form; click a transaction or a sealed block to see its bytes.

## Layout

- `src/chain/chain.ts`: EVM setup, deployment, raw calls, system calls, queue storage reads.
- `src/chain/encoding.ts`: request calldata, system-call output decoders, credentials.
- `src/sim/consensus.ts`: consensus-layer model.
- `src/sim/simulation.ts`: actors and actions; `nextBlock()` runs the system calls and feeds the model.
- `src/ui/view.ts`: plain snapshots of the simulation for rendering.
- `src/ui/Dock.tsx`, `ChainView.tsx`, `Lanes.tsx`, `Drawer.tsx`: actions, blocks, queues and
  stakes, byte details. Animations use [motion](https://motion.dev).

## Deployment

`.github/workflows/site.yml` builds and deploys to GitHub Pages on every push to `main`.
Enable it once under Settings → Pages → Source: GitHub Actions. CI (`ci.yml`) also builds the
site on every PR.
