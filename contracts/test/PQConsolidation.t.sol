// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {SystemCallTest} from "./helpers/SystemCallTest.sol";
import {PQConsolidation} from "../src/PQConsolidation.sol";

contract PQConsolidationTest is SystemCallTest {
    address internal consolidation;

    function setUp() public {
        consolidation = address(new PQConsolidation());
        systemCall(consolidation);
    }

    function input(uint64 source, uint64 target) internal pure returns (bytes memory) {
        return abi.encodePacked(source, target);
    }

    function test_EncodesLogAndRecord() public {
        address source = address(0x1111111111111111111111111111111111111111);

        vm.recordLogs();
        assertTrue(submitAs(source, consolidation, input(0x0102030405, 2 ** 40 - 1)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 0);
        assertEq(
            logs[0].data,
            hex"1111111111111111111111111111111111111111" hex"0000000102030405"
            hex"000000ffffffffff"
        );

        assertEq(
            systemCall(consolidation),
            hex"1111111111111111111111111111111111111111" hex"0504030201000000"
            hex"ffffffffff000000"
        );
    }

    /// EIP-7251 parameters: at most 2 dequeued per block, target 1.
    function test_DequeuesTwoPerBlockAndPricesAboveOne() public {
        for (uint64 i; i < 35; i++) {
            assertTrue(submit(consolidation, input(i, i)));
        }

        assertEq(systemCall(consolidation).length, 36 * 2);
        assertEq(feeOf(consolidation), 7); // excess = 35 - 1 = 34

        assertEq(systemCall(consolidation).length, 36 * 2);
        assertEq(feeOf(consolidation), 6); // empty block: excess 33
    }

    function test_RevertWhen_CalldataNot16Bytes() public {
        (bool ok,) = consolidation.call{value: 1}(new bytes(15));
        assertFalse(ok);
        (ok,) = consolidation.call{value: 1}(new bytes(17));
        assertFalse(ok);
    }

    function test_StakeIdBoundaries() public {
        uint64 max = 2 ** 40 - 1;
        assertTrue(submit(consolidation, input(max, max)));
        assertFalse(submit(consolidation, input(max + 1, 0)));
        assertFalse(submit(consolidation, input(0, max + 1)));
    }
}
