// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @notice EIP-7002-style system contract: request queue with a dynamic per-request fee.
/// @dev The interface is raw calldata, not the Solidity ABI; the contract has no ABI functions
///      (a selector match would otherwise hijack raw requests). Reverts carry no data.
///      Calls are dispatched as in EIP-7002:
///      - caller is `SYSTEM_ADDRESS` (end of every block, no calldata): dequeue up to
///        `_maxRequestsPerBlock()` requests in FIFO order and return their encoding as raw bytes
///        (the EIP-7685 request data); update `excess` from this block's `count`; reset `count`.
///      - empty calldata, no value: return the current fee as a 32-byte big-endian word.
///      - anything else: a request, validated and stored by `_addRequest`. It must pay at least
///        the current fee; the fee is kept and overpayment is not refunded.
///      Storage slots 0-3 match EIP-7002 (excess, count, queue head, queue tail). Queue entries
///      differ from EIP-7002's contiguous slots: derived contracts declare an
///      `index => request` mapping at slot 4, so entry `i` lives at `keccak256(i ‖ 4)` (issue #6).
///      Clients never read entries directly; they come out through the system call.
///      Deployment sets `excess` to `EXCESS_INHIBITOR`, which blocks requests until the first
///      system call.
///
///      Genesis embedding must keep `queueHead <= queueTail` and, when not inhibited,
///      `excess + count < 2^256`; otherwise the end-of-block system call reverts and every block
///      is invalid. A fresh deployment or slot 0 = inhibitor with slots 1-3 zero satisfies this.
abstract contract SystemRequestQueue {
    address internal constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint256 internal constant EXCESS_INHIBITOR = type(uint256).max;
    uint256 internal constant MIN_REQUEST_FEE = 1;
    uint256 internal constant REQUEST_FEE_UPDATE_FRACTION = 17;

    /// @dev fake_exponential(1, excess, 17) overflows uint256 for every excess >= this value.
    ///      The fee there exceeds 1e55 ETH, so requests are effectively impossible already.
    uint256 internal constant FEE_OVERFLOW_EXCESS = 2893;

    /// @dev Stake IDs are 40-bit values; larger IDs would be truncated on the consensus layer.
    uint64 internal constant MAX_STAKE_ID = 2 ** 40 - 1;

    uint256 internal excess; // slot 0
    uint256 internal count; // slot 1
    uint256 internal queueHead; // slot 2
    uint256 internal queueTail; // slot 3

    constructor() {
        excess = EXCESS_INHIBITOR;
    }

    fallback(bytes calldata input) external payable returns (bytes memory) {
        if (msg.sender == SYSTEM_ADDRESS) return _processSystemCall();

        uint256 fee = _getFee();
        if (input.length == 0) {
            if (msg.value != 0) revert();
            return abi.encode(fee);
        }

        if (msg.value < fee) revert();
        // State is written before `_addRequest` validates the input; a rejected request relies
        // on its revert to roll these writes back. Keep this whole path in one call frame.
        count += 1;
        uint256 index = queueTail;
        queueTail = index + 1;
        _addRequest(index, input);
        return "";
    }

    function _getFee() private view returns (uint256) {
        uint256 currentExcess = excess;
        if (currentExcess == EXCESS_INHIBITOR) revert();
        // Revert without data instead of reaching a checked-arithmetic Panic (issue #5).
        if (currentExcess >= FEE_OVERFLOW_EXCESS) revert();
        return _fakeExponential(MIN_REQUEST_FEE, currentExcess, REQUEST_FEE_UPDATE_FRACTION);
    }

    function _processSystemCall() private returns (bytes memory requests) {
        uint256 head = queueHead;
        uint256 tail = queueTail;
        uint256 dequeued = tail - head;
        if (dequeued > _maxRequestsPerBlock()) dequeued = _maxRequestsPerBlock();

        requests = _encodeRequests(head, dequeued);

        if (head + dequeued == tail) {
            queueHead = 0;
            queueTail = 0;
        } else {
            queueHead = head + dequeued;
        }

        uint256 previousExcess = excess;
        if (previousExcess == EXCESS_INHIBITOR) previousExcess = 0;
        uint256 total = previousExcess + count;
        excess = total > _targetRequestsPerBlock() ? total - _targetRequestsPerBlock() : 0;
        count = 0;
    }

    /// @dev Approximates `factor * e ** (numerator / denominator)`, as in EIP-4844 / EIP-7002.
    ///      Callers bound `numerator` below `FEE_OVERFLOW_EXCESS`, so the loop never overflows.
    function _fakeExponential(uint256 factor, uint256 numerator, uint256 denominator)
        private
        pure
        returns (uint256)
    {
        uint256 output;
        uint256 accum = factor * denominator;
        for (uint256 i = 1; accum > 0; i++) {
            output += accum;
            accum = (accum * numerator) / (denominator * i);
        }
        return output / denominator;
    }

    // --- Hooks ------------------------------------------------------------------------------

    function _targetRequestsPerBlock() internal pure virtual returns (uint256);

    function _maxRequestsPerBlock() internal pure virtual returns (uint256);

    /// @dev Validate `input` (non-empty), store it at queue `index`, and emit its log. The fee
    ///      has been charged; revert to reject.
    function _addRequest(uint256 index, bytes calldata input) internal virtual;

    /// @dev Encode `n` queued requests starting at queue index `start`, in order.
    function _encodeRequests(uint256 start, uint256 n) internal view virtual returns (bytes memory);

    // --- Helpers ----------------------------------------------------------------------------

    function _checkStakeId(uint64 stakeId) internal pure {
        if (stakeId > MAX_STAKE_ID) revert();
    }

    /// @dev EIP-7002-style anonymous log: no topics, raw request bytes as data.
    function _log0(bytes memory data) internal {
        assembly ("memory-safe") {
            log0(add(data, 0x20), mload(data))
        }
    }

    function _le64(uint64 v) internal pure returns (bytes8) {
        v = ((v & 0xFF00FF00FF00FF00) >> 8) | ((v & 0x00FF00FF00FF00FF) << 8);
        v = ((v & 0xFFFF0000FFFF0000) >> 16) | ((v & 0x0000FFFF0000FFFF) << 16);
        return bytes8((v >> 32) | (v << 32));
    }

    /// @dev Copy `len` bytes of `src` from `srcOffset` into `dst` at `dstOffset`; returns the
    ///      offset in `dst` just past the copy.
    function _copy(
        bytes memory dst,
        uint256 dstOffset,
        bytes memory src,
        uint256 srcOffset,
        uint256 len
    ) internal pure returns (uint256) {
        assembly ("memory-safe") {
            mcopy(add(add(dst, 0x20), dstOffset), add(add(src, 0x20), srcOffset), len)
        }
        return dstOffset + len;
    }

    function _write(bytes memory dst, uint256 offset, bytes memory src)
        internal
        pure
        returns (uint256)
    {
        return _copy(dst, offset, src, 0, src.length);
    }
}
