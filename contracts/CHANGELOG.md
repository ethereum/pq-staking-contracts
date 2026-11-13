# Changelog

## 1.0.0 (2026-11-13)


### ⚠ BREAKING CHANGES

* PQStaking, PQConsolidation and PQWithdrawal are no longer released.
* the registration contracts implement EIP-8483. A request is the EIP's input followed by a leanXMSS proof of possession at leaf 0.
* a registration request is 2444 bytes and must carry a leanXMSS proof of possession.
* proofs of possession must be signed at the leaf derived from the message.
* registration requests must carry a valid leanXMSS-K proof of possession.
* registration calldata and system-call output formats changed.
* registration calldata and system-call output formats changed.

### Features

* add EIP-8413 staking and registration contracts with release pipeline ([81545cc](https://github.com/ethereum/pq-staking-contracts/commit/81545cc8e242806aac6b126d52887361935aa229))
* add the leanXMSS verifier, tested on EthLib's cases ([f20b0d0](https://github.com/ethereum/pq-staking-contracts/commit/f20b0d00e4546a1616b72c8f0d05171c70e39cd7))
* derive the proof-of-possession leaf from the signed message ([5ef4465](https://github.com/ethereum/pq-staking-contracts/commit/5ef4465473f4460d19b9e98d5f73a7228fc0dfc5)), closes [#2](https://github.com/ethereum/pq-staking-contracts/issues/2) [#6](https://github.com/ethereum/pq-staking-contracts/issues/6)
* EIP-7002-style system contracts for registration, consolidation and withdrawal ([49ce0c6](https://github.com/ethereum/pq-staking-contracts/commit/49ce0c6756084e4e5e5446dfead08d05f347d573))
* fix PQ key and signature sizes at 32 and 2400 bytes ([d54dd92](https://github.com/ethereum/pq-staking-contracts/commit/d54dd92aa44cb65e6b1dceb15184e062a8ae3eb1))
* PQ-only registration, no BLS key ([e2c8c93](https://github.com/ethereum/pq-staking-contracts/commit/e2c8c937c7fffd5b0321b758c20acb389fb99772))
* register PQ material as in EIP-8483, with a leanXMSS proof of possession ([c442572](https://github.com/ethereum/pq-staking-contracts/commit/c4425722d7fbb2dd838ad879135c133faec1b7fb))
* remove the staking, consolidation and withdrawal contracts ([ff0f551](https://github.com/ethereum/pq-staking-contracts/commit/ff0f551d35ee157f083f54825895b619c564f6c4))
* verify registration proofs of possession on the EL (leanXMSS-K) ([a9a7509](https://github.com/ethereum/pq-staking-contracts/commit/a9a7509661b6c05482db44bfe59bbb6c6e1d9258))
* verify registration proofs of possession with leanXMSS ([9ab0588](https://github.com/ethereum/pq-staking-contracts/commit/9ab058862a4c789c9809c309608f602b2e402f6e))


### Bug Fixes

* red-team low-severity findings ([ea39b75](https://github.com/ethereum/pq-staking-contracts/commit/ea39b757af34473e53be80275b612666bafedf77)), closes [#3](https://github.com/ethereum/pq-staking-contracts/issues/3) [#4](https://github.com/ethereum/pq-staking-contracts/issues/4) [#5](https://github.com/ethereum/pq-staking-contracts/issues/5)


### Performance Improvements

* compute the proof-of-possession message in assembly ([6ac26ea](https://github.com/ethereum/pq-staking-contracts/commit/6ac26eafc0b5f6e43b16300c95d88e99cc3ab691))
