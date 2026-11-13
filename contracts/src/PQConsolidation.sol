// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {SystemRequestQueue} from "./SystemRequestQueue.sol";

/// @title PQConsolidation
/// @notice Consolidation system contract per EIP-8413, with the EIP-7251 fee and queue: moves a
///         registered validator's balance from a source stake into a target stake, identified by
///         stake ID instead of public key.
/// @dev The consensus layer resolves the stake IDs to their validators and applies the EIP-7251
///      rules, including checking `source_address` against the source stake's withdrawal
///      credentials. Unregistered stakes are rejected there.
///
///      Request calldata (16 bytes): source_stake_id (u64 BE) ++ target_stake_id (u64 BE)
///      Log: log0, data = source_address (20) ++ calldata
///      System call output, 36 bytes per request:
///        source_address (20) ++ source_stake_id (u64 LE) ++ target_stake_id (u64 LE)
contract PQConsolidation is SystemRequestQueue {
    uint256 internal constant TARGET_REQUESTS_PER_BLOCK = 1;
    uint256 internal constant MAX_REQUESTS_PER_BLOCK = 2;

    struct Consolidation {
        address sourceAddress;
        uint64 sourceStakeId;
        uint64 targetStakeId;
    }

    mapping(uint256 index => Consolidation) private queue; // slot 4

    function _addRequest(uint256 index, bytes calldata input) internal override {
        if (input.length != 16) revert();
        uint64 sourceStakeId = uint64(bytes8(input[0:8]));
        uint64 targetStakeId = uint64(bytes8(input[8:16]));
        _checkStakeId(sourceStakeId);
        _checkStakeId(targetStakeId);

        queue[index] = Consolidation({
            sourceAddress: msg.sender, sourceStakeId: sourceStakeId, targetStakeId: targetStakeId
        });
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
            Consolidation storage entry = queue[start + i];
            pos = _write(
                out,
                pos,
                abi.encodePacked(
                    entry.sourceAddress, _le64(entry.sourceStakeId), _le64(entry.targetStakeId)
                )
            );
        }
    }
}
