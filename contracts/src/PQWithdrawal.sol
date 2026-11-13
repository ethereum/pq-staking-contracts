// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {SystemRequestQueue} from "./SystemRequestQueue.sol";

/// @title PQWithdrawal
/// @notice Withdrawal, exit and unregistered-stake recovery system contract per EIP-8413, with
///         the EIP-7002 fee and queue. Requests are keyed by stake ID instead of public key.
/// @dev The consensus layer checks `source_address` against the stake's withdrawal credentials
///      and interprets the request by the stake's state:
///      - registered validator: EIP-7002 rules; amount 0 is a full exit, otherwise partial.
///      - unregistered (no validator, no pending registration): amount 0 recovers the full
///        balance via the recovery queue; any other amount is ignored.
///      - registration pending, validator not yet created: ignored.
///      Amount 0 therefore always means "withdraw everything" for the owner.
///
///      Request calldata (16 bytes): stake_id (u64 BE) ++ amount_gwei (u64 BE)
///      Log: log0, data = source_address (20) ++ calldata
///      System call output, 36 bytes per request:
///        source_address (20) ++ stake_id (u64 LE) ++ amount_gwei (u64 LE)
contract PQWithdrawal is SystemRequestQueue {
    uint256 internal constant TARGET_REQUESTS_PER_BLOCK = 2;
    uint256 internal constant MAX_REQUESTS_PER_BLOCK = 16;

    struct Withdrawal {
        address sourceAddress;
        uint64 stakeId;
        uint64 amountGwei;
    }

    mapping(uint256 index => Withdrawal) private queue; // slot 4

    function _addRequest(uint256 index, bytes calldata input) internal override {
        if (input.length != 16) revert();
        uint64 stakeId = uint64(bytes8(input[0:8]));
        uint64 amountGwei = uint64(bytes8(input[8:16]));
        _checkStakeId(stakeId);

        queue[index] =
            Withdrawal({sourceAddress: msg.sender, stakeId: stakeId, amountGwei: amountGwei});
        _log0(abi.encodePacked(msg.sender, input));
    }

    function _targetRequestsPerBlock() internal pure override returns (uint256) {
        return TARGET_REQUESTS_PER_BLOCK;
    }

    function _maxRequestsPerBlock() internal pure override returns (uint256) {
        return MAX_REQUESTS_PER_BLOCK;
    }

    function _encodeRequests(uint256 start, uint256 n)
        internal
        view
        override
        returns (bytes memory out)
    {
        out = new bytes(36 * n);
        uint256 pos;
        for (uint256 i; i < n; i++) {
            Withdrawal storage entry = queue[start + i];
            pos = _write(
                out,
                pos,
                abi.encodePacked(entry.sourceAddress, _le64(entry.stakeId), _le64(entry.amountGwei))
            );
        }
    }
}
