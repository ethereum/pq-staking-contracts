// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

/// EthLib's leanXMSS vectors, copied by `xmss/sync-vectors.sh`.
library LeanXmssVectors {
    // forge-lint: disable-next-line(screaming-snake-case-const)
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant DIR = "test/vectors/ethlib/xmss/";

    struct VerifyCase {
        string name;
        bytes publicKey;
        bytes message;
        bytes signature;
        /// The case's output, with null (an input of the wrong length) as false.
        bool expected;
    }

    struct SignatureIndexCase {
        string name;
        bytes signature;
        /// False when the output is null: a signature of the wrong length.
        bool accepted;
        uint256 index;
    }

    function loadVerify() internal view returns (VerifyCase[] memory cases) {
        string[] memory dirs = caseDirs("verify");
        cases = new VerifyCase[](dirs.length);
        for (uint256 i; i < dirs.length; i++) {
            VerifyCase memory c = cases[i];
            c.name = name(dirs[i]);
            // The files are flat, so splitting on the quotes yields the hex strings between
            // fixed separators.
            string[] memory parts = split(dirs[i]);
            require(parts.length == 7, "unexpected data.yaml");
            require(eq(parts[0], "input:\n  public_key: "), "unexpected data.yaml");
            require(eq(parts[2], "\n  message: "), "unexpected data.yaml");
            require(eq(parts[4], "\n  signature: "), "unexpected data.yaml");
            c.publicKey = vm.parseBytes(parts[1]);
            c.message = vm.parseBytes(parts[3]);
            c.signature = vm.parseBytes(parts[5]);
            string memory output = vm.trim(vm.replace(parts[6], "output: ", ""));
            if (eq(output, "true")) c.expected = true;
            else require(eq(output, "false") || eq(output, "null"), "unexpected output");
        }
    }

    function loadSignatureIndex() internal view returns (SignatureIndexCase[] memory cases) {
        string[] memory dirs = caseDirs("signature_index");
        cases = new SignatureIndexCase[](dirs.length);
        for (uint256 i; i < dirs.length; i++) {
            SignatureIndexCase memory c = cases[i];
            c.name = name(dirs[i]);
            string[] memory parts = split(dirs[i]);
            require(parts.length == 3, "unexpected data.yaml");
            require(eq(parts[0], "input:\n  signature: "), "unexpected data.yaml");
            c.signature = vm.parseBytes(parts[1]);
            string memory output = vm.trim(vm.replace(parts[2], "output: ", ""));
            if (!eq(output, "null")) {
                c.accepted = true;
                c.index = vm.parseUint(output);
            }
        }
    }

    /// Whether a case can be passed as `verify(bytes32, bytes32, bytes)`.
    function representable(VerifyCase memory c) internal pure returns (bool) {
        return c.publicKey.length == 32 && c.message.length == 32;
    }

    function eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// The directories of the cases of one operation.
    function caseDirs(string memory operation) private view returns (string[] memory dirs) {
        Vm.DirEntry[] memory entries = vm.readDir(string.concat(DIR, operation));
        dirs = new string[](entries.length);
        uint256 n;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].isDir) dirs[n++] = entries[i].path;
        }
        assembly {
            mstore(dirs, n)
        }
    }

    function name(string memory dir) private pure returns (string memory) {
        string[] memory path = vm.split(dir, "/");
        return path[path.length - 1];
    }

    /// A case's file, split on its quotes.
    function split(string memory dir) private view returns (string[] memory) {
        return vm.split(vm.readFile(string.concat(dir, "/data.yaml")), "'");
    }
}
