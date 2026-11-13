# leanXMSS

Registration proofs of possession are leanXMSS signatures. The spec is EthLib's
[`EthLib/Cryptography/Xmss`](https://github.com/ethereum/EthLib/tree/master/EthLib/Cryptography/Xmss),
a Lean implementation of the note "leanXMSS for Ethereum PQ-Consensus" in leanVM's
[`doc/lean_xmss`](https://github.com/leanEthereum/leanVM/tree/main/doc/lean_xmss).

This repository follows EthLib at the commit in
[`contracts/test/vectors/ethlib/COMMIT`](../contracts/test/vectors/ethlib/COMMIT). The Solidity
verifier (`contracts/src/LeanXmss.sol`) must match the spec at that commit byte for byte.

| | |
| --- | --- |
| Public key | 32 bytes: root (16) ‖ public parameter (16) |
| Signature | 2,404 bytes: leaf index (u32 little-endian) ‖ bottom layer (1,200) ‖ top layer (1,200) |
| Leaf indices | 2³², each a one-time key |
| Verification | 172 Keccak-256 calls |

## Registration proof of possession

EthLib doesn't define this part, so it is specified here.

Proofs of possession use the PoP range: bottom tree `0xFFFF`, i.e. leaf indices
`0xFFFF0000 … 0xFFFFFFFF`. These 65,536 leaf indices MUST NOT be used for attestations.

- Message:
  `M = K(DOMAIN ‖ chain_id (32) ‖ registration_contract (20) ‖ stake_id (8) ‖ pq_pubkey (32))`,
  with `K` Keccak-256, `DOMAIN = K("leanXMSS registration proof of possession v1")` and the
  integers big-endian.
- Leaf index: `0xFFFF0000 | (M mod 2¹⁶)`, i.e. the leaf within the tree is the last two bytes of
  `M`. A leanXMSS signature carries its leaf index, and the registration contract rejects a
  signature made at any other leaf.

Binding the registration contract's address stops a copied validator registration from being
replayed into the builder registration contract (and the reverse). Binding `stake_id` and
`chain_id` stops replay onto another stake or chain.

A leaf index must never sign two different messages: its key is one-time, and two signatures
reveal every chain at the smaller of their two positions. Deriving the leaf from `M` gives each
distinct registration (chain, role, stake) its own leaf, so registering one key several times
does not reuse a leaf (issue #2). Two different messages land on the same leaf with probability
about `n² / 2¹⁷` for `n` registrations of one key (0.005% for 3). A signer MUST track the PoP
leaves it has used and refuse to sign a different message on one of them; the operator then
registers with another stake.

## Vectors

| Path | Contents | Written by |
| --- | --- | --- |
| `contracts/test/vectors/ethlib/xmss/` | EthLib's `verify` and `signature_index` cases | `./sync-vectors.sh <ethlib-commit>` |
| `contracts/test/vectors/leanxmss_pop.json` | Proofs of possession for the registration tests | `cargo run --release` |

```sh
./sync-vectors.sh <ethlib-commit>   # copies EthLib's cases at that commit and records it
cargo run --release                 # ~20 s on 16 cores
```

The generator (`src/main.rs`) signs with leanVM's Rust implementation of leanXMSS, at the commit
pinned in [`Cargo.toml`](Cargo.toml). leanVM tests it on the same EthLib cases. The outputs are
committed; CI does not regenerate them.

To follow a newer spec, run `./sync-vectors.sh` with the new EthLib commit, and fix the verifier
until the tests pass. If the scheme changed, also move the leanVM commit in `Cargo.toml` to one
that follows it and run the generator again.
