// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

/// Raw-calldata helpers for the EIP-7002-style system contracts.
abstract contract SystemCallTest is Test {
    address internal constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    /// End-of-block system call, as a client performs it: from SYSTEM_ADDRESS, no calldata.
    function systemCall(address target) internal returns (bytes memory requests) {
        vm.prank(SYSTEM_ADDRESS);
        (bool ok, bytes memory out) = target.call("");
        assertTrue(ok, "system call failed");
        return out;
    }

    /// Fee getter: empty calldata, no value, returns a 32-byte word.
    function feeOf(address target) internal returns (uint256) {
        (bool ok, bytes memory out) = target.call("");
        assertTrue(ok, "fee getter failed");
        assertEq(out.length, 32);
        return abi.decode(out, (uint256));
    }

    /// Submit a request paying exactly the current fee; returns whether it was accepted.
    function submit(address target, bytes memory input) internal returns (bool ok) {
        (ok,) = target.call{value: feeOf(target)}(input);
    }

    function submitAs(address sender, address target, bytes memory input)
        internal
        returns (bool ok)
    {
        uint256 fee = feeOf(target);
        vm.deal(sender, sender.balance + fee);
        vm.prank(sender);
        (ok,) = target.call{value: fee}(input);
    }
}
