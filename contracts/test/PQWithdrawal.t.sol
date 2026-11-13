// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {SystemCallTest} from "./helpers/SystemCallTest.sol";
import {PQWithdrawal} from "../src/PQWithdrawal.sol";

/// Covers the shared SystemRequestQueue behavior (fee, inhibitor, queue, system call) through
/// PQWithdrawal, plus the withdrawal calldata, log and record encoding.
contract PQWithdrawalTest is SystemCallTest {
    uint256 internal constant MAX_PER_BLOCK = 16;

    address internal withdrawals;

    function setUp() public {
        withdrawals = address(new PQWithdrawal());
        systemCall(withdrawals); // first system call clears the inhibitor
    }

    function input(uint64 stakeId, uint64 amountGwei) internal pure returns (bytes memory) {
        return abi.encodePacked(stakeId, amountGwei);
    }

    function test_InhibitorBlocksRequestsUntilFirstSystemCall() public {
        address fresh = address(new PQWithdrawal());

        (bool ok,) = fresh.call("");
        assertFalse(ok, "fee getter must revert while inhibited");
        (ok,) = fresh.call{value: 1 ether}(input(0, 0));
        assertFalse(ok, "request must revert while inhibited");

        assertEq(systemCall(fresh).length, 0);
        assertEq(feeOf(fresh), 1);
    }

    function test_EncodesLogAndRecord() public {
        address source = address(0x1111111111111111111111111111111111111111);

        vm.recordLogs();
        assertTrue(submitAs(source, withdrawals, input(0x0102030405, 0x0a0b0c0d0e0f1011)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 0);
        assertEq(
            logs[0].data,
            hex"1111111111111111111111111111111111111111" hex"0000000102030405"
            hex"0a0b0c0d0e0f1011"
        );

        assertEq(
            systemCall(withdrawals),
            hex"1111111111111111111111111111111111111111" hex"0504030201000000"
            hex"11100f0e0d0c0b0a"
        );
    }

    function test_DequeuesAtMostMaxPerBlockInFifoOrder() public {
        for (uint64 i; i < MAX_PER_BLOCK + 4; i++) {
            assertTrue(submit(withdrawals, input(i, 0)));
        }

        bytes memory first = systemCall(withdrawals);
        assertEq(first.length, 36 * MAX_PER_BLOCK);
        for (uint256 i; i < MAX_PER_BLOCK; i++) {
            assertEq(stakeIdAt(first, i), i);
        }

        bytes memory second = systemCall(withdrawals);
        assertEq(second.length, 36 * 4);
        for (uint256 i; i < 4; i++) {
            assertEq(stakeIdAt(second, i), MAX_PER_BLOCK + i);
        }

        assertEq(systemCall(withdrawals).length, 0);

        // Queue drained and reset: new requests are dequeued normally.
        assertTrue(submit(withdrawals, input(99, 0)));
        bytes memory third = systemCall(withdrawals);
        assertEq(third.length, 36);
        assertEq(stakeIdAt(third, 0), 99);
    }

    /// Reference values from EIP-7002 `fake_exponential(1, excess, 17)`.
    function test_FeeFollowsExcessAcrossBlocks() public {
        for (uint64 i; i < 36; i++) {
            assertTrue(submit(withdrawals, input(i, 0)));
        }
        systemCall(withdrawals); // excess = 36 - 2 = 34
        assertEq(feeOf(withdrawals), 7);

        systemCall(withdrawals); // empty block: excess 32
        assertEq(feeOf(withdrawals), 6);

        systemCall(withdrawals); // excess 30
        assertEq(feeOf(withdrawals), 5);
    }

    function test_RequestsAtTargetKeepMinimumFee() public {
        for (uint256 b; b < 5; b++) {
            assertTrue(submit(withdrawals, input(1, 0)));
            assertTrue(submit(withdrawals, input(2, 0)));
            systemCall(withdrawals);
        }
        assertEq(feeOf(withdrawals), 1);
    }

    function test_RevertWhen_FeeTooLow() public {
        for (uint64 i; i < 36; i++) {
            assertTrue(submit(withdrawals, input(i, 0)));
        }
        systemCall(withdrawals);

        (bool ok,) = withdrawals.call{value: 6}(input(0, 0));
        assertFalse(ok);
        (ok,) = withdrawals.call{value: 7}(input(0, 0));
        assertTrue(ok);
    }

    function test_OverpaymentIsKept() public {
        (bool ok,) = withdrawals.call{value: 1 ether}(input(0, 0));
        assertTrue(ok);
        assertEq(withdrawals.balance, 1 ether);
    }

    function test_FeeGetterRejectsValue() public {
        (bool ok,) = withdrawals.call{value: 1}("");
        assertFalse(ok);
    }

    /// Issue #5: at the fee-overflow boundary the fee getter and requests revert without data.
    function test_FeeOverflowBoundaryRevertsWithoutData() public {
        vm.store(withdrawals, bytes32(0), bytes32(uint256(2892)));
        uint256 fee = feeOf(withdrawals);
        assertGt(fee, 1e70);

        vm.store(withdrawals, bytes32(0), bytes32(uint256(2893)));
        (bool ok, bytes memory data) = withdrawals.call("");
        assertFalse(ok);
        assertEq(data.length, 0);

        vm.deal(address(this), type(uint256).max);
        (ok, data) = withdrawals.call{value: type(uint256).max}(input(1, 0));
        assertFalse(ok);
        assertEq(data.length, 0);
    }

    function test_RevertWhen_CalldataNot16Bytes() public {
        (bool ok,) = withdrawals.call{value: 1}(new bytes(15));
        assertFalse(ok);
        (ok,) = withdrawals.call{value: 1}(new bytes(17));
        assertFalse(ok);
    }

    function test_StakeIdBoundary() public {
        assertTrue(submit(withdrawals, input(2 ** 40 - 1, 0)));
        assertFalse(submit(withdrawals, input(2 ** 40, 0)));
    }

    function stakeIdAt(bytes memory records, uint256 i) internal pure returns (uint256 id) {
        for (uint256 b; b < 8; b++) {
            id |= uint256(uint8(records[36 * i + 20 + b])) << (8 * b);
        }
    }
}
