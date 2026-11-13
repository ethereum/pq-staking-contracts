// Byte formats of the system contracts (see contracts/README.md). Request calldata uses
// big-endian integers; system-call output uses little-endian.
import { type Hex, bytesToHex, concat, numberToHex, sha256, slice } from 'viem'

const u64be = (v: bigint) => numberToHex(v, { size: 8 })

function readLe(bytes: Uint8Array, offset: number, length: number): bigint {
  let v = 0n
  for (let i = length - 1; i >= 0; i--) v = (v << 8n) | BigInt(bytes[offset + i])
  return v
}

// --- Request calldata -----------------------------------------------------------------------

export const encodeWithdrawal = (stakeId: bigint, amountGwei: bigint): Hex =>
  concat([u64be(stakeId), u64be(amountGwei)])

export const encodeConsolidation = (sourceStakeId: bigint, targetStakeId: bigint): Hex =>
  concat([u64be(sourceStakeId), u64be(targetStakeId)])

/** Post-quantum key and signature sizes; a registration request is exactly 2444 bytes. */
export const PQ_PUBKEY_LENGTH = 32
export const PQ_SIGNATURE_LENGTH = 2404
export const REGISTRATION_LENGTH = 8 + PQ_PUBKEY_LENGTH + PQ_SIGNATURE_LENGTH

export interface RegistrationFields {
  stakeId: bigint
  pqPubkey: Hex
  pqSignature: Hex
}

export const encodeRegistration = (r: RegistrationFields): Hex =>
  concat([u64be(r.stakeId), r.pqPubkey, r.pqSignature])

// --- System call output ---------------------------------------------------------------------

export interface WithdrawalRecord {
  sourceAddress: Hex
  stakeId: bigint
  amountGwei: bigint
}

export interface ConsolidationRecord {
  sourceAddress: Hex
  sourceStakeId: bigint
  targetStakeId: bigint
}

export function decodeWithdrawalRecords(out: Uint8Array): WithdrawalRecord[] {
  const records: WithdrawalRecord[] = []
  for (let o = 0; o < out.length; o += 36) {
    records.push({
      sourceAddress: bytesToHex(out.slice(o, o + 20)),
      stakeId: readLe(out, o + 20, 8),
      amountGwei: readLe(out, o + 28, 8),
    })
  }
  return records
}

export function decodeConsolidationRecords(out: Uint8Array): ConsolidationRecord[] {
  const records: ConsolidationRecord[] = []
  for (let o = 0; o < out.length; o += 36) {
    records.push({
      sourceAddress: bytesToHex(out.slice(o, o + 20)),
      sourceStakeId: readLe(out, o + 20, 8),
      targetStakeId: readLe(out, o + 28, 8),
    })
  }
  return records
}

/** Decode fixed 2444-byte registration records (stake_id little-endian). */
export function decodeRegistrationRecords(out: Uint8Array): RegistrationFields[] {
  const records: RegistrationFields[] = []
  for (let o = 0; o < out.length; o += REGISTRATION_LENGTH) {
    records.push({
      stakeId: readLe(out, o, 8),
      pqPubkey: bytesToHex(out.slice(o + 8, o + 8 + PQ_PUBKEY_LENGTH)),
      pqSignature: bytesToHex(out.slice(o + 8 + PQ_PUBKEY_LENGTH, o + REGISTRATION_LENGTH)),
    })
  }
  return records
}

// --- Credentials ----------------------------------------------------------------------------

/** 0x01 execution withdrawal credentials pointing at `address`. */
export const withdrawalCredentials = (address: Hex): Hex =>
  concat(['0x01', numberToHex(0, { size: 11 }), address])

export const withdrawalAddressOf = (credentials: Hex): Hex => slice(credentials, 12, 32)

/**
 * Demo assumption: version 0x01 commits to the PQ public key, `0x01 || sha256(pq_pubkey)[1:]`.
 * This mirrors EIP-8413's initial construction, which commits to a BLS key instead.
 */
export const authorizationCommitment = (pqPubkey: Hex): Hex => concat(['0x01', slice(sha256(pqPubkey), 1)])
