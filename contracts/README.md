# Contracts

Foundry project for the pq staking contracts. Run all commands from this directory.

| Contract | Description |
| --- | --- |
| `PQStaking` | Staking contract per [EIP-8413](https://github.com/ethereum/EIPs/pull/12306): `stake(withdrawalCredentials, authorizationCommitment) → stakeId` and `topup(stakeId)`. Stake creations and top-ups share one event index; a stake ID is the index of its `CreateStake` event. |
| `PQValidatorRegistration` | [EIP-8483](https://github.com/ethereum/EIPs/pull/12609)'s PQ registration request contract, with a leanXMSS proof of possession. |
| `PQBuilderRegistration` | EIP-8483's builder PQ registration request contract, with a leanXMSS proof of possession. |
| `PQConsolidation` | System contract. Queues a consolidation with the caller as source address. |
| `PQWithdrawal` | System contract. Queues a withdrawal with the caller as source address. Amount `0` requests a full exit, or recovery of an unregistered stake. |

The registration contracts follow EIP-8483: they register PQ material for validators and
builders that already exist, with no stake IDs. They are described
[below](#registration-contracts-eip-8483). The rest of this section and the next are about the
staking, consolidation and withdrawal contracts.

Consolidations, partial withdrawals and exits are keyed by stake ID. The consensus layer
applies the EIP-7251 / EIP-7002 rules, checking the caller against the stake's withdrawal
credentials.

Recovery of unregistered stake reuses the withdrawal request: the consensus layer interprets
it by the stake's state.

| Stake state | Amount `0` | Amount `> 0` |
| --- | --- | --- |
| Registered validator | Full exit | Partial withdrawal |
| Unregistered | Recover full balance | Ignored |
| Registration pending, no validator yet | Ignored | Ignored |

The consolidation and withdrawal contracts reject stake IDs above `2**40 - 1`.

## System contracts: fee, queue and system call

The consolidation and withdrawal contracts copy the
[EIP-7002](https://eips.ethereum.org/EIPS/eip-7002) system-contract design
(`SystemRequestQueue`). They are called with raw calldata, not the Solidity ABI: they have no
ABI functions, reverts carry no data, and any implementation language can match the
bytecode's behavior. Each call is dispatched as in EIP-7002:

- **System call.** At the end of every block the client calls each contract from
  `0xfffffffffffffffffffffffffffffffffffffffe` with no calldata. The call dequeues up to the
  per-block maximum in FIFO order and returns them as raw bytes (the EIP-7685 request data).
  It also sets `excess = max(0, excess + count - target)` and resets `count`.
- **Fee getter.** Empty calldata and no value returns the current fee as a 32-byte big-endian
  word: `fake_exponential(1, excess, 17)` wei. From `excess = 2893` the formula overflows
  uint256; the fee getter and requests then revert without data (the fee is already above
  10⁵⁵ ETH there).
- **Request.** Any other calldata is a request (formats below). It must pay at least the fee.
  The contract keeps the fee and does not refund overpayment. The request is stored in the
  queue and logged with `log0` (no topics).
- **Storage.** Slots 0-3 hold `excess`, `count`, queue head and queue tail, as in EIP-7002.
  Entries differ from EIP-7002's contiguous slots: slot 4 is the root of an `index → request`
  mapping, so entry `i` is at `keccak256(i ‖ 4)`. Clients read requests from the system call,
  never from storage.
- **Inhibitor.** Deployment sets `excess = 2**256 - 1`, which rejects requests and fee
  queries until the first system call.

Input integers are big-endian, as in EIP-7002. Output integers are little-endian (SSZ).

| Contract | Request calldata | `log0` data | System call output | Target / max per block |
| --- | --- | --- | --- | --- |
| `PQWithdrawal` | 16 bytes: `stake_id (u64) ++ amount_gwei (u64)` | `source_address (20) ++ calldata` | 36 bytes each: `source_address ++ stake_id (u64 LE) ++ amount_gwei (u64 LE)` | 2 / 16 |
| `PQConsolidation` | 16 bytes: `source_stake_id (u64) ++ target_stake_id (u64)` | `source_address (20) ++ calldata` | 36 bytes each: `source_address ++ source_stake_id (u64 LE) ++ target_stake_id (u64 LE)` | 1 / 2 |

Withdrawal and consolidation parameters match EIP-7002 / EIP-7251.

Example withdrawal request (full exit of stake 42) with `cast`:

```sh
fee=$(cast to-dec "$(cast call "$WITHDRAWAL_CONTRACT" 0x)")
cast send "$WITHDRAWAL_CONTRACT" "$(cast concat-hex 0x$(printf '%016x' 42) 0x0000000000000000)" --value "$fee"
```

## Registration contracts: EIP-8483

`PQValidatorRegistration` and `PQBuilderRegistration` are EIP-8483's two request contracts,
written in Solidity, with one addition: a request carries a leanXMSS proof of possession of the
XMSS key it registers, and the contract verifies it (`LeanXmss`, about 45k gas), so an invalid one
reverts and never reaches the consensus layer. The rest is the EIP's: the dispatch, the fee, the
limits, the storage layout, the log and the system call's output. The consensus layer honors a
request only from the validator's withdrawal address, or the builder's execution address.

A request is the EIP's input followed by the 2404-byte signature. The XMSS public key is the
first 32 bytes of `pq_data`, all of it for builders. The signature is neither stored nor logged.

| Contract | Request calldata | `log0` data and system call records | Target / added / dequeued per block |
| --- | --- | --- | --- |
| `PQValidatorRegistration` | 2516 bytes: `validator_pubkey (48) ‖ pq_data (64) ‖ signature (2404)` | 132 bytes each: `source_address ‖ validator_pubkey ‖ pq_data` | 128 / 256 / 1024 |
| `PQBuilderRegistration` | 2484 bytes: `builder_pubkey (48) ‖ pq_data (32) ‖ signature (2404)` | 100 bytes each: `source_address ‖ builder_pubkey ‖ pq_data` | 2 / 16 / 16 |

The proof is a signature at leaf 0 of
`M = keccak256(DOMAIN ‖ chain_id ‖ bls_pubkey ‖ xmss_pubkey)`, which binds the XMSS key to one
BLS key on one chain. Leaf 0 is the one EIP-8450 reserves for proofs of possession, and a leaf
must not sign two different messages (issue #2), so a key goes with one BLS key on one chain.
leanXMSS is specified in EthLib's
[`EthLib/Cryptography/Xmss`](https://github.com/ethereum/EthLib/tree/master/EthLib/Cryptography/Xmss);
[`xmss/`](../xmss/) has the commit this repository follows and the proof-of-possession format.

As in the EIP, the fee state is updated when a request is added, not by the system call: the
first request of a block folds the last block's count into the excess, decayed by the target for
every block since, and the requests above the target raise the fee within a block. The contracts
take requests from deployment. A system call with calldata disables the queue, and the next one
without re-enables it.

A call queuing a validator registration costs about 237k gas on fresh storage and 98k when the
queue reuses its slots, about 46k more than the EIP's bytecode: the verify, and copying the
signature. The system call dequeues a full block of 1024 records from cold storage with about
11.7M of its 30M gas, against 11.3M for the EIP's bytecode.

`scripts/sync-eip8483.sh` copies the EIP's runtime bytecode for both contracts into
`test/vectors/eip8483/`, with the ethereum/EIPs commit it read: the latest version without an
argument, or the commit given. `test/RegistrationQueue.t.sol` sends every call to both, with the
signature only in this repository's request, and checks that they agree on success, return data,
logs, storage and balance, from any storage, including states no sequence of calls reaches.

## Using the bytecode

Every [GitHub release](https://github.com/eth-act/pq-staking-contracts/releases) ships these assets:

| File | Contents |
| --- | --- |
| `<Name>.bin` | Creation bytecode (initcode): deploy via a transaction. |
| `<Name>.bin-runtime` | Runtime bytecode: embed directly, e.g. as `code` in a genesis `alloc`. |
| `<Name>.abi.json` | ABI. |
| `bytecode.json` | All of the above plus compiler settings, in one file. |
| `SHA256SUMS` | Checksums of the files above. |

Hex files are `0x`-prefixed with no trailing newline. The CBOR metadata trailer is
stripped (`cbor_metadata = false`), so bytecode changes only when code or compiler
settings change.

Contracts must not use `immutable`: the runtime bytecode would lack the constructor-set
values, so the export script rejects them.

### Constructors and genesis storage

`PQStaking` takes `migratedValidatorCount` (validator registry length `N` at the fork,
`0` for a fresh chain). Deploying from `PQStaking.bin` requires appending the ABI-encoded
`uint64`. When embedding `PQStaking.bin-runtime` in genesis with `N > 0`, set storage slot
`0` to `(N << 64) | N` (`initialEventCount` in the low 8 bytes, `eventCount` in the next 8).
The constructor's checks don't run for a genesis `alloc`, so the genesis value must satisfy
them itself: `N < 2⁴⁰` (otherwise every stake and top-up reverts) and `eventCount ≥ N`
(otherwise new stake IDs collide with migrated validator indices).

The registration contracts write no storage at deployment, as in EIP-8483, so their
`.bin-runtime` can be embedded in genesis as it is.

The consolidation and withdrawal contracts' constructors set storage slot `0` (`excess`) to
`2**256 - 1`, the inhibitor. When embedding their `.bin-runtime` in genesis, either set slot `0` to
`0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff` to keep requests
disabled until the first system call, or leave it unset to accept requests from genesis.
Leave slots 1-3 (`count`, head, tail) zero: a genesis with `head > tail`, or with
`excess + count ≥ 2²⁵⁶` while not inhibited, makes the end-of-block system call revert, which
invalidates every block.

### Reproducing a release

Compiler settings are pinned in [`foundry.toml`](foundry.toml) (solc 0.8.38, EVM `osaka`,
optimizer 200 runs).

```sh
git checkout vX.Y.Z
git submodule update --init --recursive
cd contracts
./scripts/export-bytecode.sh   # writes contracts/dist/
```

## Development

```sh
forge build
forge test
forge fmt
```
