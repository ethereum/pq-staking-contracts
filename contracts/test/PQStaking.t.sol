// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PQStaking} from "../src/PQStaking.sol";

contract PQStakingTest is Test {
    uint64 internal constant MIGRATED = 8;
    bytes32 internal constant CREDS = bytes32(uint256(1));
    bytes32 internal constant AUTH = bytes32(uint256(2));

    PQStaking internal staking;

    function setUp() public {
        staking = new PQStaking(MIGRATED);
    }

    function test_EventIndicesStartAfterMigrationPrefix() public {
        assertEq(staking.eventCount(), MIGRATED);

        vm.expectEmit(address(staking));
        emit PQStaking.CreateStake(MIGRATED, CREDS, AUTH, 32 gwei);
        uint64 stakeId = staking.stake{value: 32 ether}(CREDS, AUTH);

        assertEq(stakeId, MIGRATED);
        assertEq(staking.eventCount(), MIGRATED + 1);
        assertEq(address(staking).balance, 32 ether);
    }

    /// Mirrors the EIP example: top-ups consume indices, so stake IDs are sparse.
    function test_StakeIdsAreSparseAcrossTopUps() public {
        uint64 first = staking.stake{value: 1 ether}(CREDS, AUTH);

        vm.expectEmit(address(staking));
        emit PQStaking.TopUp(first, 2 gwei, first + 1);
        staking.topup{value: 2 ether}(first);

        vm.expectEmit(address(staking));
        emit PQStaking.TopUp(3, 1 gwei, first + 2);
        staking.topup{value: 1 ether}(3); // migrated validator

        uint64 second = staking.stake{value: 1 ether}(CREDS, AUTH);
        assertEq(second, first + 3);
        assertEq(staking.eventCount(), first + 4);
        assertEq(address(staking).balance, 5 ether);
    }

    function test_MigratedIdsAreStakes() public view {
        assertTrue(staking.isStake(0));
        assertTrue(staking.isStake(MIGRATED - 1));
        assertFalse(staking.isStake(MIGRATED));
    }

    function test_RevertWhen_TopUpTargetsTopUpIndex() public {
        uint64 stakeId = staking.stake{value: 1 ether}(CREDS, AUTH);
        staking.topup{value: 1 ether}(stakeId);
        uint64 topUpIndex = stakeId + 1;

        assertFalse(staking.isStake(topUpIndex));
        vm.expectRevert(abi.encodeWithSelector(PQStaking.UnknownStake.selector, topUpIndex));
        staking.topup{value: 1 ether}(topUpIndex);
    }

    function test_RevertWhen_TopUpTargetsUnusedIndex() public {
        vm.expectRevert(abi.encodeWithSelector(PQStaking.UnknownStake.selector, MIGRATED));
        staking.topup{value: 1 ether}(MIGRATED);
    }

    function test_RevertWhen_StakeBelowMinimum() public {
        vm.expectRevert(PQStaking.DepositTooSmall.selector);
        staking.stake{value: 1 ether - 1 gwei}(CREDS, AUTH);
    }

    function test_RevertWhen_StakeNotGweiMultiple() public {
        vm.expectRevert(PQStaking.NotGweiMultiple.selector);
        staking.stake{value: 1 ether + 1}(CREDS, AUTH);
    }

    /// Issue #3: amounts are emitted as uint64 gwei and must never wrap.
    function test_AmountBoundaryAtUint64Gwei() public {
        uint256 max = uint256(type(uint64).max) * 1 gwei;
        vm.deal(address(this), 3 * max);

        vm.expectEmit(address(staking));
        emit PQStaking.CreateStake(MIGRATED, CREDS, AUTH, type(uint64).max);
        uint64 stakeId = staking.stake{value: max}(CREDS, AUTH);

        vm.expectRevert(PQStaking.DepositTooLarge.selector);
        staking.stake{value: max + 1 gwei}(CREDS, AUTH);
        vm.expectRevert(PQStaking.DepositTooLarge.selector);
        staking.topup{value: max + 1 gwei}(stakeId);
    }

    function test_RevertWhen_TopUpBelowMinimum() public {
        vm.expectRevert(PQStaking.DepositTooSmall.selector);
        staking.topup{value: 1 ether - 1 gwei}(0);
    }

    function test_RevertWhen_TopUpNotGweiMultiple() public {
        vm.expectRevert(PQStaking.NotGweiMultiple.selector);
        staking.topup{value: 1 ether + 1}(0);
    }

    function test_RevertWhen_EventTreeFull() public {
        uint64 max = staking.MAX_EVENT_COUNT();
        PQStaking nearlyFull = new PQStaking(max - 1);

        uint64 last = nearlyFull.stake{value: 1 ether}(CREDS, AUTH);
        assertEq(last, max - 1);

        vm.expectRevert(PQStaking.EventTreeFull.selector);
        nearlyFull.stake{value: 1 ether}(CREDS, AUTH);
        vm.expectRevert(PQStaking.EventTreeFull.selector);
        nearlyFull.topup{value: 1 ether}(last);
    }

    function test_RevertWhen_MigrationPrefixFillsTree() public {
        uint64 max = staking.MAX_EVENT_COUNT();
        vm.expectRevert(PQStaking.MigrationPrefixTooLarge.selector);
        new PQStaking(max);
    }
}
