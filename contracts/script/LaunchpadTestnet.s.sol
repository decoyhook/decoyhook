// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {DecoyHook} from "../src/hook/DecoyHook.sol";
import {DecoyLaunchpad} from "../src/launchpad/DecoyLaunchpad.sol";

/// @notice Deploys the launchpad beside the testnet hook, launches one test token through it and
/// sends one buy inside its launch guard, so the whole path runs on chain once.
contract LaunchpadTestnet is Script {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    DecoyHook internal constant HOOK = DecoyHook(0xF413b15685585541fFDeE127f364Ae4cAe2FA0c4);

    function run() external {
        require(block.chainid == 46630, "testnet only");
        uint256 signer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(signer);

        vm.startBroadcast(signer);
        DecoyLaunchpad pad = new DecoyLaunchpad(POOL_MANAGER, HOOK);
        (address token, PoolId id) = pad.launch(
            DecoyLaunchpad.Launch({
                name: "Testnet Launch Token",
                symbol: "TLAUNCH",
                meta: '{"description":"Launched through the testnet launchpad."}',
                // Two ETH for the whole supply: 500,000,000 tokens per ETH.
                sqrtPriceX96: uint160(FixedPointMathLib.sqrt(uint256(500_000_000) << 192)),
                keepBps: 0,
                feeRecipient: deployer,
                bait: DecoyLaunchpad.Bait({baseFee: 3000, guardStart: 300_000, guardSeconds: 600, lpShare: 6000}),
                salt: keccak256("testnet launch 1")
            })
        );
        PoolKey memory key = pad.poolOf(token).key;
        PoolSwapTest swapper = new PoolSwapTest(POOL_MANAGER);
        swapper.swap{value: 0.0005 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -0.0005 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        console2.log("launchpad", address(pad));
        console2.log("token", token);
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("swap router", address(swapper));
    }
}
