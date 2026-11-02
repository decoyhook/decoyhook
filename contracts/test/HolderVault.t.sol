// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HolderVault} from "../src/vault/HolderVault.sol";

contract HolderVaultTest is Test {
    address internal constant POSTER = address(0xB0571);
    address internal constant GUARDIAN = address(0x6A2D);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ETH = address(0);

    HolderVault internal vault;
    MockERC20 internal decoy;

    function setUp() public {
        vault = new HolderVault(POSTER, GUARDIAN, 1 days, 200);
        decoy = new MockERC20("Decoy", "DECOY", 18);
        decoy.mint(address(this), 1_000_000e18);
        decoy.approve(address(vault), type(uint256).max);
    }

    function _leaf(address account, address asset, uint256 cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, asset, cumulative))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// A four-leaf tree: Alice and Bob, each with an ETH and a DECOY amount.
    function _tree(uint256 aliceEth, uint256 aliceDecoy, uint256 bobEth, uint256 bobDecoy)
        internal
        view
        returns (bytes32 root, bytes32[4] memory leaves, bytes32[2][4] memory proofs)
    {
        leaves = [_leaf(ALICE, ETH, aliceEth), _leaf(ALICE, address(decoy), aliceDecoy), _leaf(BOB, ETH, bobEth), _leaf(BOB, address(decoy), bobDecoy)];
        bytes32 left = _pair(leaves[0], leaves[1]);
        bytes32 right = _pair(leaves[2], leaves[3]);
        root = _pair(left, right);
        proofs = [[leaves[1], right], [leaves[0], right], [leaves[3], left], [leaves[2], left]];
    }

    function _post(bytes32 root, uint256 ethTotal, uint256 decoyTotal) internal {
        address[] memory assets = new address[](2);
        assets[0] = ETH;
        assets[1] = address(decoy);
        uint256[] memory totals = new uint256[](2);
        totals[0] = ethTotal;
        totals[1] = decoyTotal;
        vm.prank(POSTER);
        vault.propose(root, assets, totals);
        vm.warp(block.timestamp + 1 days);
        vault.activate();
    }

    function _claim(address account, uint256 ethAmount, uint256 decoyAmount, bytes32[2] memory ethProof, bytes32[2] memory decoyProof) internal {
        address[] memory assets = new address[](2);
        assets[0] = ETH;
        assets[1] = address(decoy);
        uint256[] memory cumulative = new uint256[](2);
        cumulative[0] = ethAmount;
        cumulative[1] = decoyAmount;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](2);
        proofs[1] = new bytes32[](2);
        (proofs[0][0], proofs[0][1]) = (ethProof[0], ethProof[1]);
        (proofs[1][0], proofs[1][1]) = (decoyProof[0], decoyProof[1]);
        vault.claim(account, assets, cumulative, proofs);
    }

    function test_biteStreamIsDistributableAtOnce() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.distributable(ETH), 1 ether);
    }

    function test_supplyStreamReleasesAShareEachWeek() public {
        vault.lock(address(decoy), 1000e18);
        assertEq(vault.distributable(address(decoy)), 0);
        vm.warp(block.timestamp + 6 days);
        assertEq(vault.distributable(address(decoy)), 0, "nothing before a whole week");
        vm.warp(block.timestamp + 1 days);
        assertEq(vault.distributable(address(decoy)), 20e18, "2% after one week");
        vm.warp(block.timestamp + 7 days);
        assertEq(vault.distributable(address(decoy)), 39.6e18, "2% of the rest after two");
    }

    function test_lockingMoreKeepsWhatWasReleased() public {
        vault.lock(address(decoy), 1000e18);
        vm.warp(block.timestamp + 7 days);
        vault.lock(address(decoy), 500e18);
        assertEq(vault.distributable(address(decoy)), 20e18);
        assertEq(vault.stillLocked(address(decoy)), 1480e18);
    }

    function test_rootWaitsForItsDelayAndCanBeVetoed() public {
        (bytes32 root,,) = _tree(0, 0, 0, 0);
        address[] memory none = new address[](0);
        uint256[] memory zero = new uint256[](0);
        vm.prank(POSTER);
        vault.propose(root, none, zero);
        vm.expectRevert(HolderVault.NotReady.selector);
        vault.activate();

        vm.prank(GUARDIAN);
        vault.veto();
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(HolderVault.BadRoot.selector);
        vault.activate();
    }

    function test_onlyTheRolesProposeAndVeto() public {
        address[] memory none = new address[](0);
        uint256[] memory zero = new uint256[](0);
        vm.expectRevert(HolderVault.NotPoster.selector);
        vault.propose(bytes32(uint256(1)), none, zero);
        vm.expectRevert(HolderVault.NotGuardian.selector);
        vault.veto();
    }

    function test_aRootCannotPromiseMoreThanTheVaultHas() public {
        vm.deal(address(vault), 1 ether);
        vault.lock(address(decoy), 1000e18);
        address[] memory assets = new address[](1);
        uint256[] memory totals = new uint256[](1);
        assets[0] = address(decoy);
        totals[0] = 1e18;
        vm.prank(POSTER);
        vm.expectRevert(abi.encodeWithSelector(HolderVault.OverPromised.selector, address(decoy)));
        vault.propose(bytes32(uint256(1)), assets, totals);
    }

    function test_claimsPayOnceAndRollForward() public {
        vm.deal(address(vault), 1 ether);
        vault.lock(address(decoy), 1000e18);
        vm.warp(block.timestamp + 7 days);

        (bytes32 root, , bytes32[2][4] memory proofs) = _tree(0.6 ether, 12e18, 0.4 ether, 8e18);
        _post(root, 1 ether, 20e18);
        _claim(ALICE, 0.6 ether, 12e18, proofs[0], proofs[1]);
        assertEq(ALICE.balance, 0.6 ether);
        assertEq(decoy.balanceOf(ALICE), 12e18);

        vm.expectRevert(HolderVault.NothingOwed.selector);
        _claim(ALICE, 0.6 ether, 12e18, proofs[0], proofs[1]);

        // Next week: more bites and more released supply. Bob never claimed; his amounts carry over.
        vm.deal(address(vault), address(vault).balance + 0.5 ether);
        vm.warp(block.timestamp + 7 days);
        (bytes32 next, , bytes32[2][4] memory nextProofs) = _tree(0.9 ether, 22e18, 0.6 ether, 17.6e18);
        _post(next, 1.5 ether, 39.6e18);
        _claim(ALICE, 0.9 ether, 22e18, nextProofs[0], nextProofs[1]);
        assertEq(ALICE.balance, 0.9 ether, "only the new 0.3 ETH is paid");
        _claim(BOB, 0.6 ether, 17.6e18, nextProofs[2], nextProofs[3]);
        assertEq(BOB.balance, 0.6 ether);
        assertEq(decoy.balanceOf(BOB), 17.6e18);
    }

    function test_aWrongAmountFailsTheProof() public {
        vm.deal(address(vault), 1 ether);
        (bytes32 root, , bytes32[2][4] memory proofs) = _tree(0.6 ether, 0, 0.4 ether, 0);
        _post(root, 1 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(HolderVault.BadProof.selector, ETH));
        _claim(ALICE, 0.9 ether, 0, proofs[0], proofs[1]);
    }

    function testFuzz_releaseNeverExceedsWhatWasLocked(uint96 amount, uint16 weeks_) public {
        vm.assume(amount > 0);
        decoy.mint(address(this), amount);
        vault.lock(address(decoy), amount);
        vm.warp(block.timestamp + uint256(weeks_) * 7 days);
        uint256 free = vault.distributable(address(decoy));
        assertLe(free, amount);
        assertEq(free + vault.stillLocked(address(decoy)), amount);
    }
}
