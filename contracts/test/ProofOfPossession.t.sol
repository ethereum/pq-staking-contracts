// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {LeanXmssHarness} from "./LeanXmss.t.sol";
import {RegistrationTestBase} from "./helpers/RegistrationTestBase.sol";
import {PQBuilderRegistration} from "../src/PQBuilderRegistration.sol";

/// Tests what a proof of possession binds. A proof is a signature at leaf 0, by the XMSS key, of
/// `M = keccak256(POP_DOMAIN ‖ chain_id ‖ bls_pubkey ‖ xmss_public_key)`. The proofs come from
/// the generator in xmss/.
abstract contract ProofOfPossessionTest is RegistrationTestBase {
    LeanXmssHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new LeanXmssHarness();
    }

    function popMessage(bytes memory blsPubkey, bytes32 xmssPubkey)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(POP_DOMAIN, block.chainid, blsPubkey, xmssPubkey));
    }

    /// The generator signs, at leaf 0, the same `M` that the contract checks.
    function test_ProofsSignTheMessageAtLeafZero() public view {
        assertEq(vm.parseJsonBytes32(vectors, ".popDomain"), POP_DOMAIN);
        for (uint256 i; i < 3; i++) {
            Proof memory p = proof(i);
            assertEq(p.message, popMessage(p.blsPubkey, p.xmssPubkey));
            assertEq(p.leafIndex, 0);
            assertEq(harness.signatureIndex(p.signature), 0);
            assertTrue(harness.verify(p.xmssPubkey, p.message, p.signature));
        }
    }

    /// An accepted request only stores and logs what the EIP's contract would. The signature isn't
    /// stored or logged.
    function test_StoresAndLogsNoSignature() public {
        for (uint256 i; i < 3; i++) {
            Proof memory p = proof(i);
            vm.record();
            vm.recordLogs();
            assertTrue(submit(registration, request(p)));

            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            assertEq(logs[0].topics.length, 0);
            assertEq(logs[0].data, record(address(this), p));

            // The only slots written are the fee state (0, 1 and 4), the tail (3) and the
            // request's own slots.
            uint256 first = QUEUE_OFFSET + i * slotsPerRequest();
            (, bytes32[] memory writes) = vm.accesses(registration);
            for (uint256 w; w < writes.length; w++) {
                uint256 slot = uint256(writes[w]);
                bool fee = slot == 0 || slot == 1 || slot == 3 || slot == 4;
                assertTrue(fee || (slot >= first && slot < first + slotsPerRequest()));
            }
        }
    }

    function test_RevertWhen_OtherChain() public {
        vm.chainId(1);
        assertFalse(submit(registration, request(proof(0))));
    }

    function test_RevertWhen_OtherBlsKey() public {
        Proof memory p = proof(0);
        p.blsPubkey = proof(1).blsPubkey;
        assertFalse(submit(registration, request(p)));
        p = proof(0);
        p.blsPubkey[47] ^= 0x01;
        assertFalse(submit(registration, request(p)));
    }

    /// A proof signed by one XMSS key doesn't register another one.
    function test_RevertWhen_OtherXmssKey() public {
        Proof memory p = proof(0);
        p.xmssPubkey = proof(1).xmssPubkey;
        assertFalse(submit(registration, request(p)));
    }

    /// A valid signature at leaf 0 of the message without the domain.
    function test_RevertWhen_MessageWithoutDomain() public {
        Proof memory p = proofAt(".noDomain");
        assertEq(p.message, keccak256(abi.encodePacked(block.chainid, p.blsPubkey, p.xmssPubkey)));
        assertEq(harness.signatureIndex(p.signature), 0);
        assertTrue(harness.verify(p.xmssPubkey, p.message, p.signature));
        assertFalse(submit(registration, request(p)));
    }

    /// A valid signature of `M` at leaf 1. A proof of possession must be at leaf 0.
    function test_RevertWhen_NotAtLeafZero() public {
        Proof memory p = proofAt(".wrongLeaf");
        assertEq(p.message, proof(0).message);
        assertEq(harness.signatureIndex(p.signature), 1);
        assertTrue(harness.verify(p.xmssPubkey, p.message, p.signature));
        assertFalse(submit(registration, request(p)));
    }

    function test_RevertWhen_SignatureTampered() public {
        Proof memory p = proof(0);
        for (uint256 offset = 1; offset < SIGNATURE_LENGTH; offset += 401) {
            Proof memory tampered = proof(0);
            tampered.signature[offset] = p.signature[offset] ^ 0x01;
            assertFalse(submit(registration, request(tampered)));
        }
        assertTrue(submit(registration, request(p)));
    }

    /// Calldata of any length other than a request's is rejected, including the EIP's input
    /// alone.
    function test_RevertWhen_NotRequestLength() public {
        Proof memory p = proof(0);
        assertFalse(submit(registration, input(p)));
        assertFalse(submit(registration, bytes.concat(request(p), hex"00")));
        bytes memory short = request(p);
        assembly {
            mstore(short, sub(mload(short), 1))
        }
        assertFalse(submit(registration, short));
    }
}

contract ValidatorProofOfPossessionTest is ProofOfPossessionTest {
    function isValidator() internal pure override returns (bool) {
        return true;
    }

    /// `M` binds the XMSS key, which is the first half of `pq_data`, but not the VRF data after
    /// it.
    function test_VrfDataIsNotBound() public {
        Proof memory p = proof(0);
        bytes memory changed = request(p);
        changed[48 + 32] ^= 0x01;
        assertTrue(submit(registration, changed));
    }

    /// `M` doesn't include the role, as EIP-8450 intends. A validator and a builder that share a
    /// BLS key sign the same message, so one proof registers the key for both.
    function test_OneProofForValidatorAndBuilder() public {
        Proof memory p = proof(0);
        address builders = address(new PQBuilderRegistration());
        assertTrue(submit(registration, request(p)));
        assertTrue(submit(builders, bytes.concat(p.blsPubkey, p.xmssPubkey, p.signature)));
    }
}

contract BuilderProofOfPossessionTest is ProofOfPossessionTest {
    function isValidator() internal pure override returns (bool) {
        return false;
    }
}
