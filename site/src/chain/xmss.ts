// leanXMSS proof-of-possession signing with pre-generated demo keys (from the generator in xmss/).
// Follows EthLib's leanXMSS (EthLib/Cryptography/Xmss) byte for byte; the registration contract
// verifies the result.
import { type IHasher, createKeccak } from 'hash-wasm'
import { type Hex, bytesToHex, concat, hexToBytes, keccak256, numberToHex, toBytes } from 'viem'
import demoKeys from '../keys/leanxmss-keys.json'

export interface DemoKey {
  seed: Hex
  pubkey: Hex
  /** Top layer for bottom tree 0xFFFF: it signs that tree's root, the same for every PoP leaf. */
  topSignature: Hex
  /** Level `storedLevel` of the PoP bottom tree; lower levels are rebuilt per signature. */
  storedLevel: number
  bottomLevelNodes: Hex
  bottomRoot: Hex
}

export const DEMO_KEYS = demoKeys as DemoKey[]

const N = 16
const HEIGHT = 16
const CHAINS = 58
const TARGET_SUM = 106
const MAX_RANDOMIZER_TRIALS = 2 ** 32
/** First leaf index of bottom tree 0xFFFF, the PoP tree. */
const POP_LEAF_BASE = 0xffff0000
// Address types.
const [PRF, CHAIN, LEAF, NODE, RANDOMIZER, MESSAGE] = [0, 1, 2, 3, 7, 12]

const POP_DOMAIN = keccak256(toBytes('leanXMSS registration proof of possession v1'))

/**
 * 16-byte address of a bottom-layer hash: lo (u32), hi (u24), type + 32·step, 8 zero bytes, the
 * fields little-endian. The top layer would also set bit 23 of hi.
 */
function address(type: number, lo: number, hi = 0, step = 0): Uint8Array {
  const a = new Uint8Array(16)
  const view = new DataView(a.buffer)
  view.setUint32(0, lo, true)
  view.setUint32(4, hi | ((type + 32 * step) << 24), true)
  return a
}

// The scheme's hashing runs in WebAssembly: a signature tries about 2^20 randomizers, one hash
// each, which takes several seconds in JavaScript. signProofOfPossession loads it.
let keccak: IHasher

/** Keccak-256 over the concatenated parts. */
function hash(...parts: Uint8Array[]): Uint8Array {
  keccak.init()
  for (const part of parts) keccak.update(part)
  return keccak.digest('binary')
}

/** Th(P, A, payload): the first 16 bytes of the hash of P ‖ A ‖ payload. */
function th(P: Uint8Array, a: Uint8Array, ...payload: Uint8Array[]): Uint8Array {
  return hash(P, a, ...payload).slice(0, N)
}

/** The starts of the chains of bottom key `e`. One hash of the seed starts two, with its halves. */
function chainStarts(P: Uint8Array, S: Uint8Array, e: number): Uint8Array[] {
  const starts: Uint8Array[] = []
  for (let t = 0; t < CHAINS / 2; t++) {
    const pair = hash(P, address(PRF, e, t), S)
    starts.push(pair.slice(0, N), pair.slice(N))
  }
  return starts
}

/** Chain `i` of bottom key `e`, from `x` at position 0 to position `to`. The index follows the value. */
function chain(P: Uint8Array, e: number, i: number, x: Uint8Array, to: number): Uint8Array {
  const index = new Uint8Array(N)
  index[0] = i
  for (let step = 0; step < to; step++) x = th(P, address(CHAIN, e, 0, step), x, index)
  return x
}

/** The parents, at `level`, of the nodes `below`, the first parent at index `first`. */
function parents(P: Uint8Array, level: number, first: number, below: Uint8Array[]): Uint8Array[] {
  return Array.from({ length: below.length / 2 }, (_, k) =>
    th(P, address(NODE, first + k, level), below[2 * k], below[2 * k + 1]),
  )
}

/** The digits of a digest that is a codeword: its digits past the 58th are zero, the others sum to 106. */
function codeword(digest: Uint8Array): number[] | undefined {
  if (digest[15] !== 0 || digest[14] >> 4 !== 0) return undefined
  const digits = Array.from({ length: CHAINS }, (_, i) => (digest[i >> 2] >> (2 * (i & 3))) & 3)
  return digits.reduce((a, b) => a + b, 0) === TARGET_SUM ? digits : undefined
}

/** Message the registration proof of possession signs. */
export function popMessage(chainId: bigint, registrationContract: Hex, stakeId: bigint, pubkey: Hex): Hex {
  return keccak256(
    concat([POP_DOMAIN, numberToHex(chainId, { size: 32 }), registrationContract, numberToHex(stakeId, { size: 8 }), pubkey]),
  )
}

/** PoP leaf index for `message`: in bottom tree 0xFFFF, the leaf its last two bytes name. */
export function popLeafIndex(message: Hex): number {
  return (POP_LEAF_BASE | Number(BigInt(message) & 0xffffn)) >>> 0
}

/** Path of bottom key `e` in the PoP tree. Rebuilds the 2^storedLevel-leaf subtree around it. */
function bottomPath(key: DemoKey, P: Uint8Array, S: Uint8Array, e: number): Uint8Array[] {
  const stored = key.storedLevel
  // Node indices count from the layer's first leaf, so a node's is its first leaf's, shifted.
  const first = ((e >>> stored) << stored) >>> 0

  // Leaves of the subtree: the ends of a key's chains hashed into one leaf each.
  let level: Uint8Array[] = []
  for (let leaf = first; leaf < first + (1 << stored); leaf++) {
    const ends = chainStarts(P, S, leaf).map((start, i) => chain(P, leaf, i, start, 3))
    level.push(th(P, address(LEAF, leaf), ...ends))
  }

  const path: Uint8Array[] = []
  let index = e - first
  for (let h = 1; h <= stored; h++) {
    path.push(level[index ^ 1])
    level = parents(P, h, first >>> h, level)
    index >>= 1
  }

  // Levels at and above the stored one come from the published nodes.
  const storedBytes = hexToBytes(key.bottomLevelNodes)
  let upper: Uint8Array[] = Array.from({ length: 1 << (HEIGHT - stored) }, (_, k) => storedBytes.slice(k * N, (k + 1) * N))
  index = (first - POP_LEAF_BASE) >>> stored
  if (bytesToHex(upper[index]) !== bytesToHex(level[0])) throw new Error('demo key: rebuilt subtree does not match')
  for (let h = stored + 1; h <= HEIGHT; h++) {
    path.push(upper[index ^ 1])
    upper = parents(P, h, POP_LEAF_BASE >>> h, upper)
    index >>= 1
  }
  if (bytesToHex(upper[0]) !== key.bottomRoot) throw new Error('demo key: rebuilt root does not match')
  return path
}

/** Sign `message` at its PoP leaf. Returns the 2404-byte signature. */
export async function signProofOfPossession(key: DemoKey, message: Hex): Promise<Hex> {
  keccak ??= await createKeccak(256)
  // Every secret derives from S, the hash of the scheme's name then the seed.
  const S = hash(toBytes('leanXMSS'), hexToBytes(key.seed))
  const P = hexToBytes(key.pubkey).slice(N)
  const M = hexToBytes(message)
  const e = popLeafIndex(message)

  // The randomizers tried are R_0 + c, as 16-byte little-endian integers, R_0 a hash of the seed
  // and the message. The first whose digest is a codeword signs: about 2^20 trials on average.
  const input = concat([P, address(MESSAGE, e), M, th(P, address(RANDOMIZER, e), S, M)])
  const rho = input.subarray(input.length - N)
  let digits = codeword(hash(input))
  for (let c = 1; !digits; c++) {
    if (c === MAX_RANDOMIZER_TRIALS) throw new Error('no randomizer gives a codeword')
    for (let k = 0; k < N; k++) {
      rho[k] = (rho[k] + 1) & 0xff
      if (rho[k] !== 0) break
    }
    digits = codeword(hash(input))
  }

  const values = chainStarts(P, S, e).map((start, i) => chain(P, e, i, start, digits[i]))

  // Leaf index (u32 little-endian), then the bottom layer, then the top one.
  const leafIndex = new Uint8Array(4)
  new DataView(leafIndex.buffer).setUint32(0, e, true)
  return bytesToHex(concat([leafIndex, rho, ...values, ...bottomPath(key, P, S, e), hexToBytes(key.topSignature)]))
}
