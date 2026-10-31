// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DecoyHook} from "../src/hook/DecoyHook.sol";

contract DecoyHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    address internal constant TEAM = address(0x7EA7);
    address internal constant VAULT = address(0xFA017);

    IPoolManager internal manager;
    DecoyHook internal hook;
    PoolSwapTest internal swapper;
    PoolModifyLiquidityTest internal lp;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal refKey;
    PoolKey internal key;

    function setUp() public {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        address at = address(uint160(0x4444 << 144) | FLAGS);
        deployCodeTo("DecoyHook.sol:DecoyHook", abi.encode(manager, VAULT), at);
        hook = DecoyHook(at);
        swapper = new PoolSwapTest(manager);
        lp = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("Token", "TKN", 18);
        MockERC20 b = new MockERC20("Quote", "QTE", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        for (uint256 i; i < 2; i++) {
            MockERC20 t = i == 0 ? token0 : token1;
            t.mint(address(this), 1e30);
            t.approve(address(swapper), type(uint256).max);
            t.approve(address(lp), type(uint256).max);
        }

        refKey = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(address(0)));
        manager.initialize(refKey, PRICE_1_1);
        _addLiquidity(refKey);

        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(at));
        hook.register(key, _rules());
        manager.initialize(key, PRICE_1_1);
        _addLiquidity(key);
    }

    function _rules() internal view returns (DecoyHook.Rules memory) {
        return DecoyHook.Rules({
            baseFee: 3000,
            deadBand: 3000,
            cap: 50_000,
            guardStart: 200_000,
            guardSeconds: 60,
            capture: 5000,
            lpShare: 6000,
            teamShare: 2500,
            holderShare: 1500,
            tokenIsCurrency0: true,
            team: TEAM,
            refPool: refKey.toId()
        });
    }

    function _addLiquidity(PoolKey memory k) internal {
        lp.modifyLiquidity(k, IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0}), "");
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal {
        swapper.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// Lifts the reference pool's price, then lets two blocks pass so swaps can use the new read.
    function _openGap() internal {
        vm.warp(block.timestamp + 120);
        _swap(refKey, false, -2e19);
        vm.roll(block.number + 1);
        hook.poke(key);
        vm.roll(block.number + 1);
    }

    function test_opensOnlyWithRegisteredRules() public {
        PoolKey memory other = PoolKey(key.currency0, key.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, key.hooks);
        vm.expectRevert();
        manager.initialize(other, PRICE_1_1);
    }

    function test_rulesAreFixedOnceOpen() public {
        vm.expectRevert(DecoyHook.AlreadyOpen.selector);
        hook.register(key, _rules());
    }

    function test_registrationBelongsToItsCaller() public {
        PoolKey memory other = PoolKey(key.currency0, key.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, key.hooks);
        DecoyHook.Rules memory hostile = _rules();
        hostile.team = address(0xBAD);
        vm.prank(address(0xBAD));
        hook.register(other, hostile);
        hook.register(other, _rules());
        manager.initialize(other, PRICE_1_1);
        assertEq(hook.rulesOf(other.toId()).team, TEAM);
    }

    function test_rejectsBadRules() public {
        PoolKey memory other = PoolKey(key.currency0, key.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, key.hooks);
        DecoyHook.Rules memory rules = _rules();
        rules.holderShare = 5000;
        rules.lpShare = 2500;
        vm.expectRevert(DecoyHook.BadRules.selector);
        hook.register(other, rules);
        rules = _rules();
        rules.cap = 200_000;
        vm.expectRevert(DecoyHook.BadRules.selector);
        hook.register(other, rules);
    }

    function test_noGapPaysTheBaseFee() public {
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 2);
        (uint24 lpFee, uint24 take,) = hook.quoteFees(key, true);
        assertEq(lpFee, 3000);
        assertEq(take, 0);
        _swap(key, true, -1e18);
        _swap(key, false, -1e18);
        assertEq(hook.teamOwed(TEAM, key.currency0), 0);
        assertEq(hook.teamOwed(TEAM, key.currency1), 0);
    }

    function test_gapClosingSwapPaysTheBite() public {
        _openGap();
        (uint24 lpFee, uint24 take, uint24 gap) = hook.quoteFees(key, false);
        assertGt(gap, 3000, "gap above the dead band");
        assertGt(take, 0);
        assertGt(lpFee, 3000);
        assertApproxEqAbs(uint256(lpFee - 3000) * 4000, uint256(take) * 6000, 10_000, "LPs keep 60% of the bite, to a pip");

        uint256 before = token0.balanceOf(address(this));
        _swap(key, false, -1e19);
        uint256 got = token0.balanceOf(address(this)) - before;
        uint256 team = hook.teamOwed(TEAM, key.currency0);
        uint256 holders = hook.vaultOwed(key.currency0);
        assertGt(team, 0);
        assertApproxEqAbs(team * 1500, holders * 2500, 4000, "team and holders split 25:15, to a wei");
        assertGt(got, 0);
    }

    function test_swapAwayFromTheReferencePaysBase() public {
        _openGap();
        (uint24 lpFee, uint24 take,) = hook.quoteFees(key, true);
        assertEq(lpFee, 3000);
        assertEq(take, 0);
    }

    function test_referenceFromTheSameBlockIsNotUsed() public {
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 1);
        _swap(refKey, false, -2e19);
        hook.poke(key);
        (,, uint24 gapNow) = hook.quoteFees(key, false);
        vm.roll(block.number + 1);
        (,, uint24 gapNext) = hook.quoteFees(key, false);
        assertGt(gapNext, gapNow, "the new read counts only from the next block");
    }

    function test_launchGuardChargesBuysOnly() public {
        (uint24 buyFee, uint24 buyTake,) = hook.quoteFees(key, false);
        (uint24 sellFee, uint24 sellTake,) = hook.quoteFees(key, true);
        assertGt(uint256(buyFee) + buyTake, 150_000, "a buy at open pays most of the guard");
        assertEq(sellFee, 3000);
        assertEq(sellTake, 0);
        vm.warp(block.timestamp + 61);
        (buyFee, buyTake,) = hook.quoteFees(key, false);
        assertEq(buyFee, 3000);
        assertEq(buyTake, 0);
    }

    function test_sellsGoThroughDuringTheGuard() public {
        _swap(key, true, -5e19);
    }

    function test_teamClaimsAndHoldersAreSwept() public {
        _openGap();
        _swap(key, false, -1e19);
        uint256 owedTeam = hook.teamOwed(TEAM, key.currency0);
        uint256 owedVault = hook.vaultOwed(key.currency0);

        vm.prank(TEAM);
        hook.claim(key.currency0);
        assertEq(token0.balanceOf(TEAM), owedTeam);
        assertEq(hook.teamOwed(TEAM, key.currency0), 0);

        hook.sweep(key.currency0);
        assertEq(token0.balanceOf(VAULT), owedVault);

        vm.prank(TEAM);
        vm.expectRevert(DecoyHook.NothingOwed.selector);
        hook.claim(key.currency0);
    }

    function testFuzz_feesStayInBounds(uint96 push, bool upward, bool zeroForOne, uint16 later) public {
        vm.warp(block.timestamp + bound(later, 0, 200));
        _swap(refKey, !upward, -int256(bound(push, 1e15, 5e19)));
        vm.roll(block.number + 1);
        hook.poke(key);
        vm.roll(block.number + 1);
        (uint24 lpFee, uint24 take,) = hook.quoteFees(key, zeroForOne);
        uint256 total = uint256(lpFee) + take;
        assertGe(total, 3000);
        assertLe(total, 200_000);
        assertLe(lpFee, LPFeeLibrary.MAX_LP_FEE);
        _swap(key, zeroForOne, -1e17);
    }
}
