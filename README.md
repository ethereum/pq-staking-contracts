# pq-staking-contracts

Staking and registration contracts for pq validators and builders.

| Directory | Contents |
| --- | --- |
| [`contracts/`](contracts/) | Foundry project: contracts, tests, bytecode export. Released bytecode docs live here. |
| [`xmss/`](xmss/) | leanXMSS, the signature scheme of the proofs of possession. EthLib specifies it. This directory says which EthLib commit is followed here, defines the proof-of-possession format, and has the generator for the contract test vectors. |

## Releases

Releases are managed by [release-please](https://github.com/googleapis/release-please) and
cover `contracts/` only: commits that touch nothing in it do not produce a release.

Commits on `main` must follow [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `feat!:` …). release-please keeps a release PR open with the next version
and changelog; merging it tags the release (`vX.Y.Z`), after which CI compiles the contracts
and attaches the bytecode assets described in [`contracts/README.md`](contracts/README.md).
