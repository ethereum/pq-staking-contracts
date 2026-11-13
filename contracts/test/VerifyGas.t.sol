// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LeanXmssHarness} from "./LeanXmss.t.sol";
import {LeanXmssVectors} from "./helpers/LeanXmssVectors.sol";

/// Calls a contract and returns the gas that call's frame used.
contract Meter {
    // forge-lint: disable-next-line(screaming-snake-case-const)
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function measure(address to, bytes calldata data) external returns (uint256) {
        (bool ok,) = to.call(data);
        require(ok);
        return vm.lastCallGas().gasTotalUsed;
    }
}

contract VerifyGasTest is Test {
    /// For each of EthLib's valid vectors, snapshots two numbers in `snapshots/verify.json`: the
    /// gasUsed of a transaction calling `verify`, which includes its intrinsic gas or calldata
    /// floor, and the gas of that call's execution alone, ABI decoding included. Forge only runs
    /// a call from a test as its own transaction under isolation, which is on by default since
    /// Foundry 1.9.0, and only for a CALL. `verify` is pure, so the test calls it with a low-level
    /// call.
    function test_VerifyGas() public {
        vm.skip(!vm.isIsolateMode(), "measures transactions, so needs --isolate");
        string memory group = "verify";
        address harness = address(new LeanXmssHarness());
        Meter meter = new Meter();
        LeanXmssVectors.VerifyCase[] memory cases = LeanXmssVectors.loadVerify();
        uint256 n;
        for (uint256 i; i < cases.length; i++) {
            LeanXmssVectors.VerifyCase memory c = cases[i];
            if (!c.expected) continue;
            bytes memory data = abi.encodeCall(
                LeanXmssHarness.verify, (bytes32(c.publicKey), bytes32(c.message), c.signature)
            );
            (bool ok, bytes memory ret) = harness.call(data);
            assertTrue(ok && abi.decode(ret, (bool)), c.name);
            vm.snapshotGasLastCall(group, string.concat("transaction ", c.name));
            vm.snapshotValue(
                group, string.concat("execution ", c.name), meter.measure(harness, data)
            );
            n++;
        }
        assertEq(n, 4);
    }
}
