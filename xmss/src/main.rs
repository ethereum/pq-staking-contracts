//! Generates the proof-of-possession vectors for the contract tests, using leanVM's
//! implementation of leanXMSS. Run with `--release`.
//!
//! Output (committed):
//!   contracts/test/vectors/leanxmss_pop.json

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::thread;

use primitives::hash::hash;
use signatures::lean_xmss::*;

const CONTRACT_VECTORS: &str = "../contracts/test/vectors/leanxmss_pop.json";

/// The forge tests etch the registration contracts at these addresses, on this chain id.
const FORGE_CHAIN_ID: u64 = 31337;
const VALIDATOR_REGISTRATION: [u8; 20] = address(0x7a11);
const BUILDER_REGISTRATION: [u8; 20] = address(0xb111);

/// Proofs of possession sign in bottom tree 0xFFFF, whose leaf indices never sign attestations.
const POP_TREE: u32 = 0xFFFF;
const POP_LEAF_BASE: LeafIndex = POP_TREE << LAYER_HEIGHT;

fn main() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(CONTRACT_VECTORS);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, contract_vectors()).unwrap();
    println!("wrote {}", path.canonicalize().unwrap().display());
}

/// A key's seed, from a label: these keys are public.
fn seed(label: &str) -> Seed {
    hash(format!("pq-staking-contracts {label}").as_bytes())
}

fn pop_domain() -> [u8; 32] {
    hash(b"leanXMSS registration proof of possession v1")
}

/// The message a registration's proof of possession signs.
fn pop_message(
    chain_id: u64,
    contract: &[u8; 20],
    stake_id: u64,
    pubkey: &[u8; PUB_KEY_SIZE],
) -> Message {
    let mut chain_id_word = [0; 32];
    chain_id_word[24..].copy_from_slice(&chain_id.to_be_bytes());
    hash(
        &[
            &pop_domain()[..],
            &chain_id_word,
            contract,
            &stake_id.to_be_bytes(),
            pubkey,
        ]
        .concat(),
    )
}

/// The leaf index that signs the proof of possession of `message`: in the PoP tree, the leaf
/// its last two bytes name.
fn pop_leaf(message: &Message) -> LeafIndex {
    POP_LEAF_BASE | LeafIndex::from(u16::from_be_bytes([message[30], message[31]]))
}

/// Signs with one key, and refuses to sign two different messages at one leaf index.
struct Signer {
    sk: LeanXmssSecretKey,
    pubkey: [u8; PUB_KEY_SIZE],
    used: HashMap<LeafIndex, Message>,
}

impl Signer {
    fn new(label: &str) -> Self {
        let (sk, pk) = key_gen_from_seed(seed(label));
        Self {
            sk,
            pubkey: pk.to_bytes(),
            used: HashMap::new(),
        }
    }

    fn sign(&mut self, leaf_index: LeafIndex, message: &Message) -> [u8; SIG_SIZE] {
        let signed = self.used.entry(leaf_index).or_insert(*message);
        assert_eq!(
            signed, message,
            "leaf index {leaf_index:#x} already signed another message"
        );
        let signature = sign(&self.sk, message, leaf_index).unwrap();
        verify(
            &LeanXmssPublicKey::from_bytes(&self.pubkey),
            message,
            &signature,
        )
        .expect("the signature verifies");
        signature.to_bytes()
    }

    /// A registration of this key for `stake_id` in `contract`.
    fn registration(&mut self, contract: &[u8; 20], stake_id: u64) -> Registration {
        let message = pop_message(FORGE_CHAIN_ID, contract, stake_id, &self.pubkey);
        let leaf_index = pop_leaf(&message);
        Registration {
            contract: *contract,
            stake_id,
            pubkey: self.pubkey,
            message,
            leaf_index,
            signature: self.sign(leaf_index, &message),
        }
    }
}

struct Registration {
    contract: [u8; 20],
    stake_id: u64,
    pubkey: [u8; PUB_KEY_SIZE],
    message: Message,
    leaf_index: LeafIndex,
    signature: [u8; SIG_SIZE],
}

impl Registration {
    fn json(&self, indent: &str) -> String {
        object(
            indent,
            &[
                ("contract", hex(&self.contract)),
                ("stakeId", self.stake_id.to_string()),
                ("pubkey", hex(&self.pubkey)),
                ("message", hex(&self.message)),
                ("leafIndex", self.leaf_index.to_string()),
                ("signature", hex(&self.signature)),
            ],
        )
    }
}

fn contract_vectors() -> String {
    let (mut key_a, mut key_b) = thread::scope(|s| {
        let key_b = s.spawn(|| Signer::new("test key B"));
        (Signer::new("test key A"), key_b.join().unwrap())
    });

    // Key A registers twice, as a validator and as a builder, and each registration lands on its
    // own leaf.
    let registrations = [
        key_a.registration(&VALIDATOR_REGISTRATION, 3),
        key_a.registration(&BUILDER_REGISTRATION, 3),
        key_b.registration(&VALIDATOR_REGISTRATION, 4),
    ];
    assert_ne!(registrations[0].leaf_index, registrations[1].leaf_index);

    // The first registration's message signed at a neighbouring PoP leaf: a valid signature that
    // the registration contract must reject, because it derives the leaf from the message.
    let wrong_leaf = registrations[0].leaf_index ^ 1;
    let wrong_leaf = Registration {
        leaf_index: wrong_leaf,
        signature: key_a.sign(wrong_leaf, &registrations[0].message),
        ..registrations[0]
    };

    let registrations: Vec<_> = registrations.iter().map(|r| r.json("    ")).collect();
    object(
        "",
        &[
            ("chainId", FORGE_CHAIN_ID.to_string()),
            ("popDomain", hex(&pop_domain())),
            (
                "registrations",
                format!("[\n    {}\n  ]", registrations.join(",\n    ")),
            ),
            ("wrongLeafRegistration", wrong_leaf.json("  ")),
        ],
    ) + "\n"
}

const fn address(low: u16) -> [u8; 20] {
    let mut out = [0; 20];
    out[18] = (low >> 8) as u8;
    out[19] = low as u8;
    out
}

/// A JSON object of the given fields, each value already JSON, closed at `indent`.
fn object(indent: &str, fields: &[(&str, String)]) -> String {
    let fields: Vec<_> = fields
        .iter()
        .map(|(name, value)| format!("{indent}  \"{name}\": {value}"))
        .collect();
    format!("{{\n{}\n{indent}}}", fields.join(",\n"))
}

/// A JSON string of the bytes in hex.
fn hex(bytes: &[u8]) -> String {
    let digits: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("\"0x{digits}\"")
}
