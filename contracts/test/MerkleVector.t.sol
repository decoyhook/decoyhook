// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MerkleProofLib} from "solmate/src/utils/MerkleProofLib.sol";

contract ProofCheck {
    function check(bytes32[] calldata proof, bytes32 root, bytes32 leaf) external pure returns (bool) {
        return MerkleProofLib.verify(proof, root, leaf);
    }
}

/// @notice A tree built by the API's root builder (apps/api/src/holders/merkle.ts) must verify here
/// exactly as the vault verifies claims. The vector below was printed by that builder.
contract MerkleVectorTest is Test {
    ProofCheck internal checker = new ProofCheck();
    address internal constant ASSET = 0x9e61574C0652cdf9c512C2947b3b9e1A2010BcDb;
    bytes32 internal constant ROOT = 0xce097a09aef634a1c82c1740447a2f9c5bdfaf9d35ddf90af312161bf149cfe1;

    function leaf(address account, uint256 cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, ASSET, cumulative))));
    }

    function test_builderProofsVerify() public view {
        bytes32[] memory a = new bytes32[](2);
        a[0] = 0x3fecf1e3cb5c6f2f46b8672badc145f1b48cf1181c3b579d18537ca8d24cb64e;
        a[1] = 0xb8e07ab8587494862a2d82b0998b6954f886aa0c7db773e5e50a91d2a309f296;
        bytes32[] memory b = new bytes32[](1);
        b[0] = 0x2e7989c3f962832b4f3b5cc1a86a161bbe96ea673f31f8b241045f1fc35a7556;
        bytes32[] memory c = new bytes32[](2);
        c[0] = 0x65ba2be1a9364f62e925ea739f375e383f0bbaf067238deeeedafc5a87b7c60e;
        c[1] = 0xb8e07ab8587494862a2d82b0998b6954f886aa0c7db773e5e50a91d2a309f296;
        assertTrue(checker.check(a, ROOT, leaf(address(0xa1), 1000)));
        assertTrue(checker.check(b, ROOT, leaf(address(0xb2), 1001)));
        assertTrue(checker.check(c, ROOT, leaf(address(0xc3), 1002)));
        assertFalse(checker.check(a, ROOT, leaf(address(0xa1), 1001)));
    }
}
