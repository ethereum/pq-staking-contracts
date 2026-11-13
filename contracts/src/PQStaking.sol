// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title PQStaking
/// @notice Staking contract following EIP-8413 (Decouple Stake from Validator Registration).
/// @dev Every stake creation and top-up appends one event and consumes one event index.
///      A stake's `stakeId` is the event index of its creation, so stake IDs are monotonic
///      but sparse. Indices `[0, initialEventCount)` are reserved for validators migrated at
///      the fork (stake ID == validator index) and are valid top-up targets.
///      The stake-event tree hashing is not yet specified by the EIP, so no root is kept.
contract PQStaking {
    uint256 public constant MIN_DEPOSIT = 1 ether;

    /// @notice Stake-event tree capacity (height 40), including the migration prefix.
    uint64 public constant MAX_EVENT_COUNT = 2 ** 40;

    /// @notice Size of the reserved migration prefix (validator registry length N at the fork).
    /// @dev Storage, not immutable, so the published runtime bytecode is complete: genesis
    ///      deployments set it via storage slot 0 together with `eventCount`.
    uint64 public initialEventCount;

    /// @notice Number of events in the stake-event tree, including the migration prefix.
    uint64 public eventCount;

    /// @notice Whether an index past the migration prefix holds a CREATE_STAKE event.
    mapping(uint64 eventIndex => bool) private createdStake;

    event CreateStake(
        uint64 indexed stakeId,
        bytes32 withdrawalCredentials,
        bytes32 authorizationCommitment,
        uint64 amountGwei
    );

    event TopUp(uint64 indexed stakeId, uint64 amountGwei, uint64 eventIndex);

    error DepositTooSmall();
    error DepositTooLarge();
    error NotGweiMultiple();
    error EventTreeFull();
    error UnknownStake(uint64 stakeId);
    error MigrationPrefixTooLarge();

    /// @param migratedValidatorCount Validator registry length N at the fork; 0 for a fresh chain.
    constructor(uint64 migratedValidatorCount) {
        if (migratedValidatorCount >= MAX_EVENT_COUNT) revert MigrationPrefixTooLarge();
        initialEventCount = migratedValidatorCount;
        eventCount = migratedValidatorCount;
    }

    /// @notice Create a stake position.
    /// @param withdrawalCredentials Controls withdrawals of the stake.
    /// @param authorizationCommitment Versioned commitment to the credential allowed to register
    ///        a validator for this stake: byte 0 is the format version, bytes 1..31 the payload.
    /// @return stakeId Event index of this CREATE_STAKE event.
    function stake(bytes32 withdrawalCredentials, bytes32 authorizationCommitment)
        external
        payable
        returns (uint64 stakeId)
    {
        uint64 amountGwei = _amountGwei();
        stakeId = _nextEventIndex();
        createdStake[stakeId] = true;
        emit CreateStake(stakeId, withdrawalCredentials, authorizationCommitment, amountGwei);
    }

    /// @notice Add balance to an existing stake position (migrated or created here).
    function topup(uint64 stakeId) external payable {
        if (!isStake(stakeId)) revert UnknownStake(stakeId);
        uint64 amountGwei = _amountGwei();
        emit TopUp(stakeId, amountGwei, _nextEventIndex());
    }

    /// @notice Whether `stakeId` identifies a stake position: a migrated validator index or the
    ///         index of a CREATE_STAKE event. Indices holding TOP_UP events are not stake IDs.
    function isStake(uint64 stakeId) public view returns (bool) {
        return stakeId < initialEventCount || createdStake[stakeId];
    }

    function _nextEventIndex() private returns (uint64 index) {
        index = eventCount;
        if (index >= MAX_EVENT_COUNT) revert EventTreeFull();
        eventCount = index + 1;
    }

    function _amountGwei() private view returns (uint64) {
        if (msg.value < MIN_DEPOSIT) revert DepositTooSmall();
        if (msg.value % 1 gwei != 0) revert NotGweiMultiple();
        uint256 amountGwei = msg.value / 1 gwei;
        // Events carry uint64 gwei; never truncate (issue #3).
        if (amountGwei > type(uint64).max) revert DepositTooLarge();
        return uint64(amountGwei);
    }
}
