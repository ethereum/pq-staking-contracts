// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {LeanXmss} from "./LeanXmss.sol";
import {SystemRequestQueue} from "./SystemRequestQueue.sol";

/// @notice Role registration queue: binds a post-quantum key to a stake created in `PQStaking`.
/// @dev The proof of possession is a leanXMSS signature verified here, so an invalid one
///      reverts on the execution layer and never reaches the consensus layer. The consensus
///      layer still checks that the stake exists and is unregistered, that the key opens the
///      stake's authorization commitment, and that the key is unused. A rejected registration
///      does not lose the stake.
///
///      Proof of possession: signature over
///        M = keccak256(POP_DOMAIN ‖ chain_id (32) ‖ this contract (20) ‖ stake_id (8) ‖ pq_pubkey (32))
///      at leaf index `POP_LEAF_BASE | (M mod 2^16)`. The leaf indices of bottom tree 0xFFFF are
///      reserved for proofs of possession and never sign attestations. XMSS leaves are one-time
///      keys, so the leaf is derived from M: each distinct registration (chain, role, stake) of a
///      key signs with its own leaf (issue #2). A leanXMSS signature carries its leaf index, and
///      one made at any other leaf is rejected. The contract address binds the role, so a
///      validator registration cannot be replayed into the builder contract or the reverse.
///
///      Request calldata (exactly 2444 bytes):
///        stake_id (u64 BE) ++ pq_pubkey (32) ++ pq_signature (2404)
///      Log: log0, data = calldata
///      System call output: concatenated 2444-byte records, i.e. SSZ `List[RegistrationRequest]`
///      of the fixed-size container
///        RegistrationRequest { stake_id: uint64, pq_pubkey: Bytes32, pq_signature: Bytes2404 }
///      Each record is the calldata with stake_id converted to little-endian.
abstract contract RegistrationQueue is SystemRequestQueue {
    uint256 internal constant TARGET_REQUESTS_PER_BLOCK = 2;
    uint256 internal constant MAX_REQUESTS_PER_BLOCK = 16;
    uint256 internal constant PQ_PUBKEY_LENGTH = 32;
    uint256 internal constant PQ_SIGNATURE_LENGTH = LeanXmss.SIGNATURE_LENGTH;

    /// @dev stake_id (8) + pq_pubkey + pq_signature.
    uint256 internal constant REQUEST_LENGTH = 8 + PQ_PUBKEY_LENGTH + PQ_SIGNATURE_LENGTH;

    /// @dev First leaf index of the PoP range (bottom tree 0xFFFF); the leaf in it comes from M.
    uint32 internal constant POP_LEAF_BASE = 0xffff0000;
    bytes32 internal constant POP_DOMAIN =
        keccak256("leanXMSS registration proof of possession v1");

    /// @dev Raw request calldata, validated on entry.
    mapping(uint256 index => bytes) private queue; // slot 4

    function _addRequest(uint256 index, bytes calldata input) internal override {
        if (input.length != REQUEST_LENGTH) revert();
        uint64 stakeId = uint64(bytes8(input[0:8]));
        _checkStakeId(stakeId);

        bytes32 pubkey = bytes32(input[8:40]);
        bytes32 message =
            keccak256(abi.encodePacked(POP_DOMAIN, block.chainid, address(this), stakeId, pubkey));
        uint32 leaf = POP_LEAF_BASE | uint32(uint16(uint256(message)));
        bytes calldata signature = input[40:];
        if (LeanXmss.signatureIndex(signature) != leaf) revert();
        if (!LeanXmss.verify(pubkey, message, signature)) revert();

        queue[index] = input;
        _log0(input);
    }

    function _targetRequestsPerBlock() internal pure override returns (uint256) {
        return TARGET_REQUESTS_PER_BLOCK;
    }

    function _maxRequestsPerBlock() internal pure override returns (uint256) {
        return MAX_REQUESTS_PER_BLOCK;
    }

    function _encodeRequests(uint256 start, uint256 n)
        internal
        view
        override
        returns (bytes memory out)
    {
        out = new bytes(REQUEST_LENGTH * n);
        uint256 pos;
        for (uint256 i; i < n; i++) {
            bytes memory raw = queue[start + i];
            // stake_id is the first 8 bytes of the request.
            // forge-lint: disable-next-line(unsafe-typecast)
            pos = _write(out, pos, abi.encodePacked(_le64(uint64(bytes8(raw)))));
            pos = _copy(out, pos, raw, 8, REQUEST_LENGTH - 8);
        }
    }
}
