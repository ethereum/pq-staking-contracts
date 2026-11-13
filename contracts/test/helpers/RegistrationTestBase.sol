// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {SystemCallTest} from "./SystemCallTest.sol";
import {PQValidatorRegistration} from "../../src/PQValidatorRegistration.sol";
import {PQBuilderRegistration} from "../../src/PQBuilderRegistration.sol";

/// Shared setup for the registration tests: one registration contract, the EIP's bytecode it
/// implements, and the proofs of possession from the generator in xmss/. Each test runs once for
/// the validator contract and once for the builder contract.
abstract contract RegistrationTestBase is SystemCallTest {
    struct Proof {
        bytes blsPubkey;
        bytes32 xmssPubkey;
        bytes32 message;
        uint256 leafIndex;
        bytes signature;
    }

    uint256 internal constant SIGNATURE_LENGTH = 2404;
    uint256 internal constant QUEUE_OFFSET = 5;
    uint256 internal constant SYSTEM_CALL_GAS_LIMIT = 30_000_000;
    bytes32 internal constant POP_DOMAIN =
        keccak256("leanXMSS registration proof of possession v1");

    /// The contract under test.
    address internal registration;
    string internal vectors;

    function setUp() public virtual {
        registration = isValidator()
            ? address(new PQValidatorRegistration())
            : address(new PQBuilderRegistration());
        vectors = vm.readFile("test/vectors/leanxmss_pop.json");
        assertEq(block.chainid, vm.parseJsonUint(vectors, ".chainId"));
    }

    function isValidator() internal pure virtual returns (bool);

    // --- The EIP's parameters ---------------------------------------------------------------

    function pqDataLength() internal pure returns (uint256) {
        return isValidator() ? 64 : 32;
    }

    function inputLength() internal pure returns (uint256) {
        return 48 + pqDataLength();
    }

    function recordLength() internal pure returns (uint256) {
        return 20 + inputLength();
    }

    function slotsPerRequest() internal pure returns (uint256) {
        return isValidator() ? 5 : 4;
    }

    function target() internal pure returns (uint256) {
        return isValidator() ? 128 : 2;
    }

    function maxAddedPerBlock() internal pure returns (uint256) {
        return isValidator() ? 256 : 16;
    }

    function maxPerBlock() internal pure returns (uint256) {
        return isValidator() ? 1024 : 16;
    }

    /// The EIP's runtime bytecode, copied by scripts/sync-eip8483.sh.
    function eipRuntime() internal view returns (bytes memory) {
        string memory file = isValidator() ? "validator.hex" : "builder.hex";
        return vm.parseBytes(vm.trim(vm.readFile(string.concat("test/vectors/eip8483/", file))));
    }

    // --- Proofs of possession -----------------------------------------------------------------

    /// Proof `i` of the generator's three valid proofs.
    function proof(uint256 i) internal view returns (Proof memory) {
        return proofAt(string.concat(".proofs[", vm.toString(i), "]"));
    }

    function proofAt(string memory key) internal view returns (Proof memory p) {
        p.blsPubkey = vm.parseJsonBytes(vectors, string.concat(key, ".blsPubkey"));
        p.xmssPubkey = vm.parseJsonBytes32(vectors, string.concat(key, ".xmssPubkey"));
        p.message = vm.parseJsonBytes32(vectors, string.concat(key, ".message"));
        p.leafIndex = vm.parseJsonUint(vectors, string.concat(key, ".leafIndex"));
        p.signature = vm.parseJsonBytes(vectors, string.concat(key, ".signature"));
    }

    /// The `pq_data` for a proof's XMSS key. It's the key itself, followed for validators by 32
    /// bytes standing in for the VRF data.
    function pqData(Proof memory p) internal pure returns (bytes memory) {
        if (!isValidator()) return abi.encodePacked(p.xmssPubkey);
        return abi.encodePacked(p.xmssPubkey, keccak256(abi.encode("vrf", p.xmssPubkey)));
    }

    /// The EIP's input: the BLS public key followed by `pq_data`.
    function input(Proof memory p) internal pure returns (bytes memory out) {
        out = bytes.concat(p.blsPubkey, pqData(p));
        assertEq(out.length, inputLength());
    }

    /// This repository's request: the EIP's input followed by the signature.
    function request(Proof memory p) internal pure returns (bytes memory) {
        return bytes.concat(input(p), p.signature);
    }

    /// The record that the contract logs, and the system call returns, for `p` sent by `sender`.
    function record(address sender, Proof memory p) internal pure returns (bytes memory) {
        return bytes.concat(bytes20(sender), input(p));
    }
}
