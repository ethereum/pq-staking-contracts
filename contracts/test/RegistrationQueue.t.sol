// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {RegistrationTestBase} from "./helpers/RegistrationTestBase.sol";

/// Compares the registration contract against the EIP's bytecode. Every call goes to both, with
/// the signature only in this repository's request, and the two must agree on success, return
/// data, logs, storage and balance.
abstract contract RegistrationQueueTest is RegistrationTestBase {
    /// Where the EIP's bytecode is etched. The EIP hasn't chosen its address yet.
    address internal constant EIP = address(0x8483);

    Proof[3] internal proofs;

    function setUp() public override {
        super.setUp();
        vm.etch(EIP, eipRuntime());
        for (uint256 i; i < 3; i++) {
            proofs[i] = proof(i);
        }
    }

    // --- Calls to both contracts --------------------------------------------------------------

    /// Calls the fee getter on both. `fee` is zero when both revert.
    function feeOfBoth() internal returns (bool ok, uint256 fee) {
        (bool okEip, bytes memory retEip) = EIP.call("");
        (bool okOurs, bytes memory retOurs) = registration.call("");
        assertEq(okOurs, okEip, "fee getter: success");
        assertEq(retOurs, retEip, "fee getter: return data");
        assertSameState();
        if (okEip) fee = abi.decode(retEip, (uint256));
        return (okEip, fee);
    }

    /// Adds proof `i` to both from `sender`, paying `value`.
    function addToBoth(address sender, uint256 i, uint256 value) internal returns (bool) {
        Proof memory p = proofs[i];
        uint256 tail = load(EIP, 3);
        vm.deal(sender, 2 * value);
        vm.recordLogs();
        vm.prank(sender);
        (bool okEip, bytes memory retEip) = EIP.call{value: value}(input(p));
        Vm.Log[] memory logsEip = vm.getRecordedLogs();
        vm.prank(sender);
        (bool okOurs, bytes memory retOurs) = registration.call{value: value}(request(p));
        Vm.Log[] memory logsOurs = vm.getRecordedLogs();

        assertEq(okOurs, okEip, "add: success");
        assertEq(retOurs, retEip, "add: return data");
        assertEq(logsOurs.length, logsEip.length, "add: logs");
        for (uint256 j; j < logsEip.length; j++) {
            assertEq(logsOurs[j].topics.length, logsEip[j].topics.length, "add: log topics");
            assertEq(logsOurs[j].data, logsEip[j].data, "add: log data");
        }
        assertSameState();
        assertSameRequests(tail, 1);
        return okEip;
    }

    /// Runs the system call on both, with `data` as calldata.
    function systemCallBoth(bytes memory data) internal returns (bytes memory records) {
        vm.prank(SYSTEM_ADDRESS);
        (bool okEip, bytes memory retEip) = EIP.call(data);
        vm.prank(SYSTEM_ADDRESS);
        (bool okOurs, bytes memory retOurs) = registration.call(data);
        assertTrue(okEip, "system call failed");
        assertEq(okOurs, okEip, "system call: success");
        assertEq(retOurs, retEip, "system call: return data");
        assertSameState();
        return retEip;
    }

    // --- State --------------------------------------------------------------------------------

    function load(address target, uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(target, bytes32(slot)));
    }

    function store(uint256 slot, uint256 value) internal {
        vm.store(EIP, bytes32(slot), bytes32(value));
        vm.store(registration, bytes32(slot), bytes32(value));
    }

    /// Sets slots 0 to 4 of both: excess, count, head, tail and last block.
    function setState(uint256 excess, uint256 count, uint256 head, uint256 tail, uint256 last)
        internal
    {
        store(0, excess);
        store(1, count);
        store(2, head);
        store(3, tail);
        store(4, last);
    }

    /// Fills `n` requests from index `from` in both, each slot with a hash of `seed` and the
    /// slot.
    function fillQueue(uint256 from, uint256 n, bytes32 seed) internal {
        unchecked {
            uint256 first = QUEUE_OFFSET + from * slotsPerRequest();
            for (uint256 slot = first; slot != first + n * slotsPerRequest(); slot++) {
                store(slot, uint256(keccak256(abi.encode(seed, slot))));
            }
        }
    }

    function assertSameState() internal view {
        for (uint256 slot; slot < QUEUE_OFFSET; slot++) {
            assertEq(load(registration, slot), load(EIP, slot), "storage slot");
        }
        assertEq(registration.balance, EIP.balance, "balance");
    }

    /// Checks that both store the same `n` requests from index `from`, and the same slot after
    /// them.
    function assertSameRequests(uint256 from, uint256 n) internal view {
        unchecked {
            uint256 first = QUEUE_OFFSET + from * slotsPerRequest();
            for (uint256 slot = first; slot != first + n * slotsPerRequest() + 1; slot++) {
                assertEq(load(registration, slot), load(EIP, slot), "queue slot");
            }
        }
    }

    /// The EIP's `fake_exponential(MIN_FEE, exponent, FEE_UPDATE_FRACTION)`.
    function feeAt(uint256 exponent) internal pure returns (uint256) {
        uint256 output;
        uint256 accum = 17;
        for (uint256 i = 1; accum > 0; i++) {
            output += accum;
            accum = (accum * exponent) / (17 * i);
        }
        return output / 17;
    }

    function sender(uint256 j) internal pure returns (address) {
        return address(uint160(0x5e4de0000 + j));
    }

    // --- Fees ---------------------------------------------------------------------------------

    /// The contract takes requests right after deployment, without a system call first.
    function test_AcceptsRequestsFromDeployment() public {
        (bool ok, uint256 fee) = feeOfBoth();
        assertTrue(ok);
        assertEq(fee, 1);
        assertTrue(addToBoth(sender(0), 0, fee));
    }

    /// Within a block, each request above the target raises the fee. In later blocks, the excess
    /// decays by the target per block.
    function test_FeeAcrossBlocks() public {
        uint256 fee;
        for (uint256 j; j < maxAddedPerBlock(); j++) {
            (, fee) = feeOfBoth();
            assertEq(fee, feeAt(j > target() ? j - target() : 0));
            assertTrue(addToBoth(sender(j), j % 3, fee));
        }
        uint256 excess = maxAddedPerBlock() - target();
        (, fee) = feeOfBoth();
        assertEq(fee, feeAt(excess));
        assertGt(fee, 1);

        // `elapsed` blocks later, the excess is that block's count minus `elapsed` targets.
        for (uint256 elapsed = 1; excess > 0; elapsed++) {
            vm.roll(block.number + 1);
            uint256 decay = elapsed * target();
            excess = maxAddedPerBlock() > decay ? maxAddedPerBlock() - decay : 0;
            (, fee) = feeOfBoth();
            assertEq(fee, feeAt(excess));
        }
        assertEq(fee, 1);

        // A request in a later block writes the decayed excess to storage.
        assertTrue(addToBoth(sender(0), 0, fee));
        assertEq(load(registration, 0), 0);
        assertEq(load(registration, 1), 1);
        assertEq(load(registration, 4), block.number);
    }

    function test_RevertWhen_FeeNotCovered() public {
        assertFalse(addToBoth(sender(0), 0, 0));
        // Overpaying works, and the contract keeps all of it.
        assertTrue(addToBoth(sender(0), 0, 5));
        assertEq(registration.balance, 5);
    }

    function test_RevertWhen_FeeGetterCarriesValue() public {
        (bool okEip,) = EIP.call{value: 1}("");
        (bool okOurs,) = registration.call{value: 1}("");
        assertFalse(okEip);
        assertFalse(okOurs);
    }

    function test_RevertWhen_BlockLimitReached() public {
        uint256 fee;
        for (uint256 j; j < maxAddedPerBlock(); j++) {
            (, fee) = feeOfBoth();
            assertTrue(addToBoth(sender(j), j % 3, fee));
        }
        (, fee) = feeOfBoth();
        assertFalse(addToBoth(sender(0), 0, fee));

        vm.roll(block.number + 1);
        (, fee) = feeOfBoth();
        assertTrue(addToBoth(sender(0), 0, fee));
    }

    function testFuzz_FeeGetter(
        uint256 excess,
        uint256 count,
        uint256 last,
        uint256 number,
        bool inhibited
    ) public {
        excess = inhibited ? type(uint256).max : bound(excess, 0, 10_000);
        vm.roll(bound(number, 0, type(uint64).max));
        setState(
            excess, bound(count, 0, 2 * maxAddedPerBlock()), 0, 0, bound(last, 0, type(uint64).max)
        );
        feeOfBoth();
    }

    /// Adds from any fee state, queue tail, sender and value, including states that no sequence
    /// of calls reaches, such as a last block after the current one.
    function testFuzz_Add(
        uint256 excess,
        uint256 count,
        uint256 last,
        uint256 number,
        uint256 tail,
        address from,
        uint256 i,
        uint256 value
    ) public {
        // The system address would take the system call path, and the test funds the sender, so
        // sending from either contract would change its balance.
        vm.assume(from != SYSTEM_ADDRESS && from != EIP && from != registration);
        vm.roll(bound(number, 0, type(uint64).max));
        setState(
            bound(excess, 0, 1000),
            bound(count, 0, maxAddedPerBlock()),
            0,
            bound(tail, 0, type(uint64).max),
            bound(last, 0, type(uint64).max)
        );
        (, uint256 fee) = feeOfBoth();
        addToBoth(from, i % 3, bound(value, 0, 2 * fee + 1));
    }

    // --- Queue and system call ----------------------------------------------------------------

    function test_SystemCallReturnsRecordsInOrder() public {
        assertEq(systemCallBoth(""), "");
        for (uint256 j; j < 3; j++) {
            assertTrue(addToBoth(sender(j), j, 1));
        }
        bytes memory expected = bytes.concat(
            record(sender(0), proofs[0]), record(sender(1), proofs[1]), record(sender(2), proofs[2])
        );
        assertEq(systemCallBoth(""), expected);
        // The queue is empty again, so head and tail go back to 0.
        assertEq(load(registration, 2), 0);
        assertEq(load(registration, 3), 0);
    }

    function test_SystemCallDequeuesAtMostMaxPerBlock() public {
        uint256 n = maxPerBlock() + 3;
        fillQueue(0, n, "queue");
        store(3, n);
        assertEq(systemCallBoth("").length, maxPerBlock() * recordLength());
        assertEq(load(registration, 2), maxPerBlock());
        assertEq(load(registration, 3), n);
        assertEq(systemCallBoth("").length, 3 * recordLength());
        assertEq(load(registration, 2), 0);
        assertEq(load(registration, 3), 0);
    }

    /// Runs the system call from any queue position, length and contents, fee state and
    /// calldata, including a head past the tail.
    function testFuzz_SystemCall(
        uint256 head,
        uint256 tail,
        uint256 excess,
        uint256 count,
        bytes32 seed,
        bytes memory data
    ) public {
        head = bound(head, 0, type(uint64).max);
        if (tail % 8 != 0) tail = head + bound(tail, 0, 40);
        else tail = bound(tail, 0, type(uint64).max);
        if (tail >= head) {
            fillQueue(head, tail - head > maxPerBlock() ? maxPerBlock() : tail - head, seed);
        }
        if (excess % 4 == 0) excess = type(uint256).max;
        setState(excess, count, head, tail, 0);
        systemCallBoth(data);
    }

    /// A full block, as the EIP sizes it: the system call dequeues the maximum from cold storage
    /// within its 30M gas.
    function test_FullBlockSystemCallFitsGasLimit() public {
        fillQueue(0, maxPerBlock(), "full block");
        store(3, maxPerBlock());
        vm.cool(EIP);
        vm.cool(registration);

        uint256[2] memory used;
        address[2] memory contracts = [EIP, registration];
        for (uint256 c; c < 2; c++) {
            vm.prank(SYSTEM_ADDRESS);
            uint256 before = gasleft();
            (bool ok, bytes memory out) = contracts[c].call{gas: SYSTEM_CALL_GAS_LIMIT}("");
            used[c] = before - gasleft();
            assertTrue(ok);
            assertEq(out.length, maxPerBlock() * recordLength());
        }
        emit log_named_uint("system call, full block, EIP bytecode", used[0]);
        emit log_named_uint("system call, full block, this contract", used[1]);
        assertLt(used[1], SYSTEM_CALL_GAS_LIMIT);
    }

    // --- Inhibitor ----------------------------------------------------------------------------

    /// A system call with calldata disables the queue, and a later one without calldata re-enables
    /// it with a fresh fee state.
    function test_Inhibitor() public {
        for (uint256 j; j < 3; j++) {
            assertTrue(addToBoth(sender(j), j, 1));
        }
        systemCallBoth(hex"01");
        assertEq(load(registration, 0), type(uint256).max);
        (bool ok,) = feeOfBoth();
        assertFalse(ok);
        assertFalse(addToBoth(sender(0), 0, 1 ether));

        systemCallBoth("");
        assertEq(load(registration, 0), 0);
        assertEq(load(registration, 1), 0);
        (, uint256 fee) = feeOfBoth();
        assertEq(fee, 1);
        assertTrue(addToBoth(sender(0), 0, fee));
    }
}

contract ValidatorRegistrationQueueTest is RegistrationQueueTest {
    function isValidator() internal pure override returns (bool) {
        return true;
    }
}

contract BuilderRegistrationQueueTest is RegistrationQueueTest {
    function isValidator() internal pure override returns (bool) {
        return false;
    }
}
