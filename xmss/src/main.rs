//! Generates the proof-of-possession vectors of the contract tests and the demo keys of the
//! site, with leanVM's implementation of leanXMSS. Run with `--release`.
//!
//! Outputs (committed):
//!   contracts/test/vectors/leanxmss_pop.json
//!   site/src/keys/leanxmss-keys.json

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::thread;

use primitives::hash::hash;
use signatures::lean_xmss::*;

const CONTRACT_VECTORS: &str = "../contracts/test/vectors/leanxmss_pop.json";
const SITE_KEYS: &str = "../site/src/keys/leanxmss-keys.json";

/// The forge tests etch the registration contracts at these addresses, on this chain id.
const FORGE_CHAIN_ID: u64 = 31337;
const VALIDATOR_REGISTRATION: [u8; 20] = address(0x7a11);
const BUILDER_REGISTRATION: [u8; 20] = address(0xb111);

/// Proofs of possession sign in bottom tree 0xFFFF, whose leaf indices never sign attestations.
const POP_TREE: u32 = 0xFFFF;
const POP_LEAF_BASE: LeafIndex = POP_TREE << LAYER_HEIGHT;

const SITE_KEY_COUNT: usize = 12;
/// The site stores this level of the PoP bottom tree, and rebuilds the 2^8-leaf subtree under one
/// of its nodes for the levels below.
const SITE_STORED_LEVEL: usize = 8;

/// The leaf index, then the two layers.
const LAYER_SIG_SIZE: usize = (SIG_SIZE - size_of::<LeafIndex>()) / 2;
/// The address type of the hash that starts a key's chains, `A_prf` in the spec.
const TWEAK_PRF: u8 = 0;

fn main() {
    let (vectors, site_keys) = thread::scope(|s| {
        let vectors = s.spawn(contract_vectors);
        let keys: Vec<_> = (0..SITE_KEY_COUNT)
            .map(|n| s.spawn(move || site_key(n)))
            .collect();
        let keys: Vec<_> = keys.into_iter().map(|key| key.join().unwrap()).collect();
        (
            vectors.join().unwrap(),
            format!("[\n{}\n]\n", keys.join(",\n")),
        )
    });
    for (path, json) in [(CONTRACT_VECTORS, vectors), (SITE_KEYS, site_keys)] {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, json).unwrap();
        println!("wrote {}", path.canonicalize().unwrap().display());
    }
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

/// Demo key `n` of the site, as a JSON object: what the site needs to sign a proof of possession
/// at any leaf of the PoP tree without building the tree.
fn site_key(n: usize) -> String {
    let seed = seed(&format!("site demo key {n}"));
    let (sk, pk) = key_gen_from_seed(seed);
    let pubkey = pk.to_bytes();
    let scheme_seed = scheme_seed(&seed);
    let pp = public_param(&scheme_seed);
    assert_eq!(pp, pubkey[N..]);

    // The top layer signs the PoP tree's root, so it is the same for every leaf of the tree. The
    // reference only gives it inside a signature, so sign once at the tree's first leaf and keep
    // the top layer. The bottom layer is checked against the tree below and dropped: that leaf
    // has revealed nothing, and the site can still sign a proof of possession with it.
    let message = hash(b"pq-staking-contracts top layer");
    let signature = sign(&sk, &message, POP_LEAF_BASE).unwrap().to_bytes();
    let (bottom, top) = signature[size_of::<LeafIndex>()..].split_at(LAYER_SIG_SIZE);

    let levels = bottom_tree(&pp, &scheme_seed, POP_TREE);
    let (randomizer, rest) = bottom.split_at(RANDOMIZER_LEN);
    let (values, path) = rest.split_at(V * N);
    let values: Vec<Digest> = values.chunks(N).map(|v| v.try_into().unwrap()).collect();
    let (_, leaf) = wots_leaf(
        &pp,
        0,
        POP_LEAF_BASE,
        &message,
        randomizer.try_into().unwrap(),
        values.as_slice().try_into().unwrap(),
    )
    .unwrap();
    assert_eq!(
        leaf, levels[0][0],
        "the rebuilt tree has the reference's first leaf"
    );
    // The first leaf's siblings are node 1 of each level, which between them cover every other
    // leaf.
    let rebuilt_path: Vec<u8> = levels[..LAYER_HEIGHT]
        .iter()
        .flat_map(|level| level[1])
        .collect();
    assert_eq!(
        path, rebuilt_path,
        "the rebuilt tree has the reference's path"
    );

    eprintln!("site key {n} done");
    object(
        "  ",
        &[
            ("seed", hex(&seed)),
            ("pubkey", hex(&pubkey)),
            ("topSignature", hex(top)),
            ("storedLevel", SITE_STORED_LEVEL.to_string()),
            (
                "bottomLevelNodes",
                hex(levels[SITE_STORED_LEVEL].as_flattened()),
            ),
            ("bottomRoot", hex(&levels[LAYER_HEIGHT][0])),
        ],
    )
}

/// The leaf of bottom key `e`, from the seed: the hash of the ends of its chains.
fn bottom_leaf(pp: &PublicParam, seed: &SchemeSeed, e: u32) -> Digest {
    let mut ends = [[0; N]; V];
    for (t, pair) in ends.chunks_mut(2).enumerate() {
        // One hash of the seed starts two chains, one from each half.
        let starts = hasher(pp, &tweak(TWEAK_PRF, layer_hi(0, t as u32), e))
            .update(seed.as_bytes())
            .finalize();
        for (half, end) in pair.iter_mut().enumerate() {
            let start = starts[half * N..][..N].try_into().unwrap();
            *end = chain(pp, 0, e, 2 * t + half, 0, CHAIN_LEN - 1, start);
        }
    }
    th(
        pp,
        &tweak(TWEAK_LEAF, layer_hi(0, 0), e),
        ends.as_flattened(),
    )
}

/// Bottom tree `tree`, level by level: level 0 its leaves, level 16 its root.
fn bottom_tree(pp: &PublicParam, seed: &SchemeSeed, tree: u32) -> Vec<Vec<Digest>> {
    let first = tree << LAYER_HEIGHT;
    let leaves = (0..1 << LAYER_HEIGHT).map(|k| bottom_leaf(pp, seed, first | k));
    let mut levels: Vec<Vec<Digest>> = vec![leaves.collect()];
    for level in 1..=LAYER_HEIGHT {
        // A bottom node's index counts from the layer's first leaf, not the tree's.
        let up = levels[level - 1].chunks(2).zip(first >> level..);
        let up = up.map(|(children, j)| {
            th(
                pp,
                &tweak(TWEAK_NODE, layer_hi(0, level as u32), j),
                children.as_flattened(),
            )
        });
        levels.push(up.collect());
    }
    levels
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
