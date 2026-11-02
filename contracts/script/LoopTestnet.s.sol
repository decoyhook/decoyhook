// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {DecoyHook} from "../src/hook/DecoyHook.sol";
import {TestToken} from "./utils/TestToken.sol";

/// @notice One turn of the loop on the testnet: a token, a plain reference pool and a decoyed pool
/// beside it, liquidity in both, a trade that moves the reference, a fresh read, and a bot-style
/// swap that closes the gap in the decoyed pool and pays the bite. Run with --slow so each step lands
/// in its own block. Claims and the sweep are a separate run, once the bite is on chain.
contract LoopTestnet is Script {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    /// 10,000 tokens per ETH, both with 18 decimals: sqrt(10,000) in Q64.96.
    uint160 internal constant START_PRICE = 100 * 2 ** 96;
    int24 internal constant FULL_LOWER = -887220;
    int24 internal constant FULL_UPPER = 887220;

    function run() external {
        require(block.chainid == 46630, "testnet only");
        DecoyHook hook = DecoyHook(vm.envAddress("HOOK"));
        uint256 signer = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(signer);

        vm.startBroadcast(signer);
        TestToken token = new TestToken("Testnet Bait Token", "TBAIT", 1_000_000e18);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(POOL_MANAGER);
        PoolSwapTest swapper = new PoolSwapTest(POOL_MANAGER);
        token.approve(address(lp), type(uint256).max);
        token.approve(address(swapper), type(uint256).max);

        PoolKey memory refKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        POOL_MANAGER.initialize(refKey, START_PRICE);
        _addLiquidity(lp, refKey);

        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        hook.register(
            key,
            DecoyHook.Rules({
                baseFee: 3000,
                deadBand: 3000,
                cap: 50_000,
                guardStart: 200_000,
                guardSeconds: 60,
                capture: 5000,
                lpShare: 6000,
                teamShare: 2500,
                holderShare: 1500,
                tokenIsCurrency0: false,
                team: deployer,
                refPool: refKey.toId()
            })
        );
        POOL_MANAGER.initialize(key, START_PRICE);
        _addLiquidity(lp, key);

        // Someone buys the token on the reference pool: its price moves and the decoyed pool lags.
        _swap(swapper, refKey, 0.0005 ether);
        hook.poke(key);
        // A bot closes the gap in the decoyed pool, buying the token there, and pays the bite.
        _swap(swapper, key, 0.0002 ether);
        vm.stopBroadcast();

        console2.log("token", address(token));
        console2.log("liquidity router", address(lp));
        console2.log("swap router", address(swapper));
        console2.log("reference pool");
        console2.logBytes32(PoolId.unwrap(refKey.toId()));
        console2.log("decoyed pool");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _addLiquidity(PoolModifyLiquidityTest lp, PoolKey memory k) internal {
        // About 0.01 ETH and 100 tokens across the full range at the start price.
        lp.modifyLiquidity{value: 0.0101 ether}(
            k, IPoolManager.ModifyLiquidityParams({tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    /// Spends `amountIn` ETH for the token.
    function _swap(PoolSwapTest swapper, PoolKey memory k, uint256 amountIn) internal {
        swapper.swap{value: amountIn}(
            k,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
