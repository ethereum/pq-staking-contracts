# Contracts

Foundry project for the pq staking contracts. Run all commands from this directory.

| Contract | Description |
| --- | --- |
| `PQStaking` | Staking contract per [EIP-8413](https://github.com/ethereum/EIPs/pull/12306): `stake(withdrawalCredentials, authorizationCommitment) → stakeId` and `topup(stakeId)`. Stake creations and top-ups share one event index; a stake ID is the index of its `CreateStake` event. |
| `PQValidatorRegistration` | System contract. Queues a registration binding a PQ key, with its signature, to a stake. |
| `PQBuilderRegistration` | Same code; queues builder registrations. The consensus layer tells the two apart by address. |
| `PQConsolidation` | System contract. Queues a consolidation with the caller as source address. |
| `PQWithdrawal` | System contract. Queues a withdrawal with the caller as source address. Amount `0` requests a full exit, or recovery of an unregistered stake. |

Validators and builders both create stake through `PQStaking`, then register their stake ID
in the registration contract for their role. Registration carries one post-quantum key
(32 bytes) and a proof of possession (2404-byte leanXMSS signature); there is no BLS key.

The registration contract verifies the proof of possession (`LeanXmss`, about 45k gas), so an
invalid one reverts and never reaches the consensus layer. The proof signs
`M = keccak256(DOMAIN ‖ chain_id ‖ registration_contract ‖ stake_id ‖ pq_pubkey)`, which binds it
to one stake, one chain and one role, at leaf index `0xFFFF0000 | (M mod 2¹⁶)`. Leaf indices
`0xFFFF0000`–`0xFFFFFFFF` are reserved for proofs of possession. XMSS leaves are one-time keys,
so deriving the leaf from `M` gives each registration of a key its own leaf (issue #2). A
leanXMSS signature carries its leaf index, and the contract rejects one made at any other leaf.
The consensus layer still checks that the stake exists
and is unregistered, that the key opens the stake's authorization commitment, and that the key
is unused. leanXMSS is specified in EthLib's
[`EthLib/Cryptography/Xmss`](https://github.com/ethereum/EthLib/tree/master/EthLib/Cryptography/Xmss);
[`xmss/`](../xmss/) has the commit this repository follows and the proof-of-possession format.

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

All request contracts reject stake IDs above `2**40 - 1`.

## System contracts: fee, queue and system call

The registration, consolidation and withdrawal contracts copy the
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
| `PQValidatorRegistration`, `PQBuilderRegistration` | 2444 bytes: `stake_id (u64) ++ pq_pubkey (32) ++ pq_signature (2404)` | calldata | 2444 bytes each: the calldata with `stake_id` little-endian, i.e. SSZ `List[RegistrationRequest]` of the fixed-size `RegistrationRequest { stake_id: uint64, pq_pubkey: Bytes32, pq_signature: Bytes2404 }` | 2 / 16 |

Withdrawal and consolidation parameters match EIP-7002 / EIP-7251. The registration
parameters reuse the EIP-7002 values. A full block of registrations (16) dequeues with about
2.8M of the 30M system-call gas. Queuing one registration, including verification, costs about
1.85M gas the first time its storage slots are written and about 0.30M when the queue reuses
them.

Example withdrawal request (full exit of stake 42) with `cast`:

```sh
fee=$(cast to-dec "$(cast call "$WITHDRAWAL_CONTRACT" 0x)")
cast send "$WITHDRAWAL_CONTRACT" "$(cast concat-hex 0x$(printf '%016x' 42) 0x0000000000000000)" --value "$fee"
```

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

The system contracts' constructors set storage slot `0` (`excess`) to `2**256 - 1`, the
inhibitor. When embedding their `.bin-runtime` in genesis, either set slot `0` to
`0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff` to keep requests
disabled until the first system call, or leave it unset to accept requests from genesis.
Leave slots 1-3 (`count`, head, tail) zero: a genesis with `head > tail`, or with
`excess + count ≥ 2²⁵⁶` while not inhibited, makes the end-of-block system call revert, which
invalidates every block.

### Reproducing a release

Compiler settings are pinned in [`foundry.toml`](foundry.toml) (solc 0.8.30, EVM `prague`,
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
