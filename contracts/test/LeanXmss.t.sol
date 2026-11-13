// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {LeanXmss} from "../src/LeanXmss.sol";
import {LeanXmssVectors} from "./helpers/LeanXmssVectors.sol";

contract LeanXmssHarness {
    function verify(bytes32 publicKey, bytes32 message, bytes calldata signature)
        external
        pure
        returns (bool)
    {
        return LeanXmss.verify(publicKey, message, signature);
    }

    function signatureIndex(bytes calldata signature) external pure returns (uint32) {
        return LeanXmss.signatureIndex(signature);
    }
}

/// The vectors are EthLib's, whose leanXMSS is the spec, so these tests check the Solidity code
/// against the spec's own cases.
contract LeanXmssTest is Test {
    LeanXmssHarness internal harness;

    function setUp() public {
        harness = new LeanXmssHarness();
    }

    /// Every `verify` case that can be passed gives its expected result.
    function test_EthLibVerifyVectors() public view {
        LeanXmssVectors.VerifyCase[] memory cases = LeanXmssVectors.loadVerify();
        uint256 checked;
        uint256 valid;
        for (uint256 i; i < cases.length; i++) {
            LeanXmssVectors.VerifyCase memory c = cases[i];
            if (!LeanXmssVectors.representable(c)) continue;
            assertEq(
                harness.verify(bytes32(c.publicKey), bytes32(c.message), c.signature),
                c.expected,
                c.name
            );
            checked++;
            if (c.expected) valid++;
        }
        assertEq(checked, 21);
        assertEq(valid, 4);
    }

    /// The cases `verify(bytes32, bytes32, bytes)` cannot take are exactly the two whose key or
    /// message is short, and both reject.
    function test_UnrepresentableVerifyVectorsReject() public view {
        LeanXmssVectors.VerifyCase[] memory cases = LeanXmssVectors.loadVerify();
        assertEq(cases.length, 23);
        uint256 excluded;
        for (uint256 i; i < cases.length; i++) {
            if (LeanXmssVectors.representable(cases[i])) continue;
            assertFalse(cases[i].expected, cases[i].name);
            assertTrue(
                LeanXmssVectors.eq(cases[i].name, "verify_short_public_key")
                    || LeanXmssVectors.eq(cases[i].name, "verify_short_message"),
                cases[i].name
            );
            excluded++;
        }
        assertEq(excluded, 2);
    }

    /// Every `signature_index` case gives its leaf index, or reverts without data when the
    /// signature is not 2404 bytes.
    function test_EthLibSignatureIndexVectors() public view {
        LeanXmssVectors.SignatureIndexCase[] memory cases = LeanXmssVectors.loadSignatureIndex();
        assertEq(cases.length, 8);
        uint256 rejected;
        for (uint256 i; i < cases.length; i++) {
            LeanXmssVectors.SignatureIndexCase memory c = cases[i];
            try harness.signatureIndex(c.signature) returns (uint32 index) {
                assertTrue(c.accepted, c.name);
                assertEq(index, c.index, c.name);
            } catch (bytes memory data) {
                assertFalse(c.accepted, c.name);
                assertEq(data.length, 0, c.name);
                rejected++;
            }
        }
        assertEq(rejected, 2);
    }
}
