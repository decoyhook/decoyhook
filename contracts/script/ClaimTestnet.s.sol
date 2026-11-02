// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DecoyHook} from "../src/hook/DecoyHook.sol";

/// @notice The last step of the testnet loop: the team claims its payout and the holders' share is
/// swept to the vault, in every currency that has something owed.
contract ClaimTestnet is Script {
    function run() external {
        require(block.chainid == 46630, "testnet only");
        DecoyHook hook = DecoyHook(vm.envAddress("HOOK"));
        Currency[2] memory currencies = [Currency.wrap(address(0)), Currency.wrap(vm.envAddress("TOKEN"))];
        uint256 signer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address account = vm.addr(signer);
        vm.startBroadcast(signer);
        for (uint256 i; i < currencies.length; i++) {
            uint256 team = hook.teamOwed(account, currencies[i]);
            uint256 vault = hook.vaultOwed(currencies[i]);
            console2.log("currency", Currency.unwrap(currencies[i]));
            console2.log("  team owed", team);
            console2.log("  vault owed", vault);
            if (team > 0) hook.claim(currencies[i]);
            if (vault > 0) hook.sweep(currencies[i]);
        }
        vm.stopBroadcast();
    }
}
