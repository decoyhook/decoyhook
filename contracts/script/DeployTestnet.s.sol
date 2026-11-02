// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {DecoyHook} from "../src/hook/DecoyHook.sol";
import {HolderVault} from "../src/vault/HolderVault.sol";

/// @notice Deploys the holder vault and the bait hook to the testnet. The hook goes through the
/// standard CREATE2 deployer at a salt mined so its address carries exactly the hook's flags.
contract DeployTestnet is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint160 internal constant FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK;

    function run() external {
        require(block.chainid == 46630, "testnet only");
        uint256 signer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(signer);

        vm.startBroadcast(signer);
        HolderVault vault = new HolderVault(deployer, deployer, 1 hours, 200);
        vm.stopBroadcast();

        bytes memory initCode = abi.encodePacked(type(DecoyHook).creationCode, abi.encode(POOL_MANAGER, address(vault)));
        bytes32 codeHash = keccak256(initCode);
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 500_000; i++) {
            salt = bytes32(i);
            predicted = vm.computeCreate2Address(salt, codeHash, CREATE2_DEPLOYER);
            if (uint160(predicted) & FLAG_MASK == FLAGS) break;
        }
        require(uint160(predicted) & FLAG_MASK == FLAGS, "no salt found");

        vm.startBroadcast(signer);
        DecoyHook hook = new DecoyHook{salt: salt}(POOL_MANAGER, address(vault));
        vm.stopBroadcast();
        require(address(hook) == predicted, "unexpected hook address");

        console2.log("vault", address(vault));
        console2.log("hook", address(hook));
        console2.log("salt", uint256(salt));
    }
}
