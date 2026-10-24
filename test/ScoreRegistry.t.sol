// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ScoreRegistry} from "../src/ScoreRegistry.sol";

contract ScoreRegistryTest is Test {
    ScoreRegistry reg;
    address admin = makeAddr("admin");
    address publisher = makeAddr("publisher");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_790_000_000);
        reg = new ScoreRegistry(admin, publisher);
    }

    function _leaf(address who, uint16 score) internal pure returns (ScoreRegistry.ScoreLeaf memory) {
        return ScoreRegistry.ScoreLeaf({
            subject: who,
            score: score,
            breadth: 200,
            tenure: 150,
            consistency: 100,
            volume: 120,
            cleanliness: 200,
            screenedOutBps: 0,
            agentLikely: true,
            keptVolumeCents: 123_45,
            firstSeen: 1_780_000_000
        });
    }

    function _hash(uint64 epoch, ScoreRegistry.ScoreLeaf memory l) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, l))));
    }

    /// Two leaves: root = hash of the sorted pair; each proof is the other leaf.
    function _publishTwo(uint64 epoch, ScoreRegistry.ScoreLeaf memory a, ScoreRegistry.ScoreLeaf memory b)
        internal
        returns (bytes32[] memory pa, bytes32[] memory pb)
    {
        bytes32 ha = _hash(epoch, a);
        bytes32 hb = _hash(epoch, b);
        bytes32 root = ha < hb ? keccak256(abi.encode(ha, hb)) : keccak256(abi.encode(hb, ha));
        vm.prank(publisher);
        reg.publish(epoch, root, uint64(block.timestamp), 2, 1, "ipfs://snapshot");
        pa = new bytes32[](1);
        pa[0] = hb;
        pb = new bytes32[](1);
        pb[0] = ha;
    }

    function test_PublishVerifyRecord() public {
        (bytes32[] memory pa,) = _publishTwo(1, _leaf(alice, 812), _leaf(bob, 300));
        assertTrue(reg.verify(1, _leaf(alice, 812), pa));
        reg.record(1, _leaf(alice, 812), pa);
        (bool found, uint16 score, bool agentLikely, uint64 epoch, uint64 asOf) = reg.scoreOf(alice);
        assertTrue(found);
        assertEq(score, 812);
        assertTrue(agentLikely);
        assertEq(epoch, 1);
        assertEq(asOf, block.timestamp);
    }

    function test_TamperedLeafFails() public {
        (bytes32[] memory pa,) = _publishTwo(1, _leaf(alice, 812), _leaf(bob, 300));
        assertFalse(reg.verify(1, _leaf(alice, 999), pa));
        vm.expectRevert(ScoreRegistry.InvalidProof.selector);
        reg.record(1, _leaf(alice, 999), pa);
    }

    function test_LeafBoundToEpoch() public {
        (bytes32[] memory pa,) = _publishTwo(1, _leaf(alice, 812), _leaf(bob, 300));
        vm.warp(block.timestamp + 1 days);
        _publishTwo(2, _leaf(alice, 500), _leaf(bob, 300));
        assertFalse(reg.verify(2, _leaf(alice, 812), pa), "an epoch-1 proof must not pass in epoch 2");
    }

    function test_RevertWhen_NotPublisher() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, reg.PUBLISHER_ROLE()
            )
        );
        vm.prank(alice);
        reg.publish(1, bytes32(uint256(1)), uint64(block.timestamp), 1, 1, "");
    }

    function test_EpochsOnlyMoveForward() public {
        _publishTwo(5, _leaf(alice, 812), _leaf(bob, 300));
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(ScoreRegistry.EpochNotNewer.selector, 5, 5));
        reg.publish(5, bytes32(uint256(1)), uint64(block.timestamp), 1, 1, "");
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(ScoreRegistry.EpochNotNewer.selector, 4, 5));
        reg.publish(4, bytes32(uint256(1)), uint64(block.timestamp), 1, 1, "");
    }

    function test_RevertWhen_BadSnapshot() public {
        vm.startPrank(publisher);
        vm.expectRevert(ScoreRegistry.BadSnapshot.selector);
        reg.publish(1, bytes32(0), uint64(block.timestamp), 1, 1, "");
        vm.expectRevert(ScoreRegistry.BadSnapshot.selector);
        reg.publish(1, bytes32(uint256(1)), uint64(block.timestamp + 1), 1, 1, "");
        vm.expectRevert(ScoreRegistry.BadSnapshot.selector);
        reg.publish(1, bytes32(uint256(1)), uint64(block.timestamp), 0, 1, "");
        vm.stopPrank();
    }

    function test_RevokeHidesScores() public {
        (bytes32[] memory pa,) = _publishTwo(1, _leaf(alice, 812), _leaf(bob, 300));
        reg.record(1, _leaf(alice, 812), pa);
        vm.prank(admin);
        reg.revoke(1);
        assertFalse(reg.verify(1, _leaf(alice, 812), pa));
        (bool found,,,,) = reg.scoreOf(alice);
        assertFalse(found);
        vm.expectRevert(abi.encodeWithSelector(ScoreRegistry.EpochRevoked.selector, 1));
        reg.record(1, _leaf(alice, 812), pa);
    }

    function test_RevertWhen_PublisherRevokes() public {
        _publishTwo(1, _leaf(alice, 812), _leaf(bob, 300));
        vm.prank(publisher);
        vm.expectRevert();
        reg.revoke(1);
    }

    function test_OlderEpochCannotOverwriteNewer() public {
        (bytes32[] memory p1,) = _publishTwo(1, _leaf(alice, 812), _leaf(bob, 300));
        vm.warp(block.timestamp + 1 days);
        (bytes32[] memory p2,) = _publishTwo(2, _leaf(alice, 640), _leaf(bob, 300));
        reg.record(2, _leaf(alice, 640), p2);
        vm.expectRevert(abi.encodeWithSelector(ScoreRegistry.StaleRecord.selector, 1, 2));
        reg.record(1, _leaf(alice, 812), p1);
        (, uint16 score,,,) = reg.scoreOf(alice);
        assertEq(score, 640);
    }

    function test_AfterRevoke_OlderValidScoreCanBeRecorded() public {
        (bytes32[] memory p1,) = _publishTwo(1, _leaf(alice, 812), _leaf(bob, 300));
        vm.warp(block.timestamp + 1 days);
        (bytes32[] memory p2,) = _publishTwo(2, _leaf(alice, 100), _leaf(bob, 300));
        reg.record(2, _leaf(alice, 100), p2);
        vm.prank(admin);
        reg.revoke(2);
        reg.record(1, _leaf(alice, 812), p1);
        (bool found, uint16 score,, uint64 epoch,) = reg.scoreOf(alice);
        assertTrue(found);
        assertEq(score, 812);
        assertEq(epoch, 1);
    }

    function test_RevertWhen_EpochInFuture() public {
        uint64 tomorrow = uint64(block.timestamp / 1 days + 1);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(ScoreRegistry.EpochInFuture.selector, tomorrow));
        reg.publish(tomorrow, bytes32(uint256(1)), uint64(block.timestamp), 1, 1, "");
    }

    function testFuzz_AnyOtherScoreFails(uint16 wrong) public {
        vm.assume(wrong != 812);
        (bytes32[] memory pa,) = _publishTwo(1, _leaf(alice, 812), _leaf(bob, 300));
        assertFalse(reg.verify(1, _leaf(alice, wrong), pa));
    }
}
