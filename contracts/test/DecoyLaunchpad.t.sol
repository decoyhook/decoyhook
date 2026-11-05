// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DecoyHook} from "../src/hook/DecoyHook.sol";
import {DecoyLaunchpad} from "../src/launchpad/DecoyLaunchpad.sol";

contract DecoyLaunchpadTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    address internal constant VAULT = address(0xFA017);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant RECIPIENT = address(0xFEE5);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    Currency internal constant ETH = Currency.wrap(address(0));

    IPoolManager internal manager;
    DecoyHook internal hook;
    DecoyLaunchpad internal pad;
    PoolSwapTest internal swapper;

    function setUp() public {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        address at = address(uint160(0x4444 << 144) | FLAGS);
        deployCodeTo("DecoyHook.sol:DecoyHook", abi.encode(manager, VAULT), at);
        hook = DecoyHook(at);
        pad = new DecoyLaunchpad(manager, hook);
        swapper = new PoolSwapTest(manager);
        vm.deal(address(this), 1_000 ether);
    }

    /// A start price of `ethCap` ETH for the whole supply.
    function _price(uint256 ethCap) internal pure returns (uint160) {
        uint256 tokensPerEth = 1_000_000_000 / ethCap;
        return uint160(FixedPointMathLib.sqrt(tokensPerEth << 192));
    }

    function _params() internal pure returns (DecoyLaunchpad.Launch memory) {
        return DecoyLaunchpad.Launch({
            name: "Bait Test",
            symbol: "BAIT",
            meta: '{"website":"https://example.com"}',
            sqrtPriceX96: _price(2),
            keepBps: 200,
            feeRecipient: RECIPIENT,
            bait: DecoyLaunchpad.Bait({baseFee: 3000, guardStart: 300_000, guardSeconds: 120, lpShare: 6000}),
            salt: bytes32(uint256(1))
        });
    }

    function _launch() internal returns (address token, PoolKey memory key) {
        vm.prank(CREATOR);
        (token,) = pad.launch(_params());
        key = pad.poolOf(token).key;
    }

    function _buy(PoolKey memory key, uint256 eth) internal {
        swapper.swap{value: eth}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(PoolKey memory key, uint256 tokens) internal {
        ERC20(Currency.unwrap(key.currency1)).approve(address(swapper), tokens);
        swapper.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(tokens), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_launchSeedsTheWholeSupplyAndKeepsNothing() public {
        (address token, PoolKey memory key) = _launch();
        ERC20 t = ERC20(token);
        assertEq(t.totalSupply(), pad.SUPPLY());
        assertEq(t.balanceOf(CREATOR), pad.SUPPLY() * 200 / 10_000);
        assertEq(t.balanceOf(address(pad)), 0);
        assertLt(t.balanceOf(DEAD), 1e9);
        assertApproxEqAbs(t.balanceOf(address(manager)), pad.SUPPLY() * 9_800 / 10_000, 1e9);
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(address(key.hooks), address(hook));

        DecoyHook.Rules memory rules = hook.rulesOf(key.toId());
        assertEq(rules.holderShare, pad.HOLDER_SHARE());
        assertEq(rules.team, RECIPIENT);
        assertFalse(rules.tokenIsCurrency0);
    }

    function test_tokenLandsWherePredicted() public {
        DecoyLaunchpad.Launch memory p = _params();
        address predicted = pad.predictToken(CREATOR, p.salt, p.name, p.symbol);
        (address token,) = _launch();
        assertEq(token, predicted);
    }

    function test_startPriceIsTheTopOfTheRange() public {
        (address token, PoolKey memory key) = _launch();
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, pad.poolOf(token).tickUpper);
        assertEq(tick % pad.TICK_SPACING(), 0);
    }

    function test_firstBuyPaysTheGuardAndTheHoldersShare() public {
        (address token, PoolKey memory key) = _launch();
        _buy(key, 0.5 ether);
        Currency t = Currency.wrap(token);
        uint256 toTeam = hook.teamOwed(RECIPIENT, t);
        uint256 toVault = hook.vaultOwed(t);
        assertGt(toTeam, 0);
        // Team 25 and holders 15 of the take, so the vault gets 15/40 of it.
        assertApproxEqRel(toVault * 40, (toTeam + toVault) * 15, 1e15);
        assertGt(ERC20(token).balanceOf(address(this)), 0);
    }

    function test_buyAfterTheGuardPaysTheBaseFeeOnly() public {
        (address token, PoolKey memory key) = _launch();
        vm.warp(block.timestamp + 121);
        _buy(key, 0.5 ether);
        assertEq(hook.teamOwed(RECIPIENT, Currency.wrap(token)), 0);
        assertEq(hook.vaultOwed(Currency.wrap(token)), 0);
    }

    function test_sellsWorkDuringTheGuard() public {
        (address token, PoolKey memory key) = _launch();
        _buy(key, 1 ether);
        uint256 held = ERC20(token).balanceOf(address(this));
        uint256 before = address(this).balance;
        _sell(key, held / 2);
        assertGt(address(this).balance, before);
    }

    function test_collectPaysTheLpFeesToTheRecipient() public {
        (address token, PoolKey memory key) = _launch();
        vm.warp(block.timestamp + 121);
        _buy(key, 2 ether);
        _sell(key, ERC20(token).balanceOf(address(this)) / 2);

        vm.prank(address(0xBEEF));
        (uint256 eth, uint256 tokens) = pad.collect(token);
        assertGt(eth, 0);
        assertGt(tokens, 0);
        assertEq(RECIPIENT.balance, eth);
        assertEq(ERC20(token).balanceOf(RECIPIENT), tokens);
        // 0.30% of the 2 ETH buy, less rounding.
        assertApproxEqRel(eth, 2 ether * 3000 / 1_000_000, 1e15);
    }

    function test_liquidityStaysAfterCollecting() public {
        (address token, PoolKey memory key) = _launch();
        DecoyLaunchpad.Pool memory pool = pad.poolOf(token);
        (uint128 before,,) = manager.getPositionInfo(key.toId(), address(pad), pool.tickLower, pool.tickUpper, 0);
        assertGt(before, 0);
        vm.warp(block.timestamp + 121);
        _buy(key, 1 ether);
        pad.collect(token);
        (uint128 left,,) = manager.getPositionInfo(key.toId(), address(pad), pool.tickLower, pool.tickUpper, 0);
        assertEq(left, before);
    }

    function test_refusesTooLargeAKeep() public {
        DecoyLaunchpad.Launch memory p = _params();
        p.keepBps = 501;
        vm.expectRevert(DecoyLaunchpad.BadLaunch.selector);
        pad.launch(p);
    }

    function test_holdersShareCannotBeSqueezed() public {
        DecoyLaunchpad.Launch memory p = _params();
        p.bait.lpShare = 8501;
        vm.expectRevert(DecoyLaunchpad.BadLaunch.selector);
        pad.launch(p);
    }

    function test_refusesAMissingFeeRecipient() public {
        DecoyLaunchpad.Launch memory p = _params();
        p.feeRecipient = address(0);
        vm.expectRevert(DecoyLaunchpad.BadLaunch.selector);
        pad.launch(p);
    }

    function test_hookLimitsStillApply() public {
        DecoyLaunchpad.Launch memory p = _params();
        p.bait.guardSeconds = 601;
        vm.expectRevert(DecoyHook.BadRules.selector);
        pad.launch(p);
    }

    function test_sameSaltTwiceReverts() public {
        _launch();
        vm.prank(CREATOR);
        vm.expectRevert();
        pad.launch(_params());
    }

    function test_onlyThePoolManagerCallsBack() public {
        vm.expectRevert(DecoyLaunchpad.NotPoolManager.selector);
        pad.unlockCallback(abi.encode(DecoyLaunchpad.Action.Collect, address(1), 0));
    }

    function test_collectRefusesAnUnknownToken() public {
        vm.expectRevert(DecoyLaunchpad.UnknownToken.selector);
        pad.collect(address(1));
    }

    function testFuzz_aBuyThenAFullSellNeverReverts(uint96 eth, uint32 wait) public {
        uint256 amount = bound(eth, 1e12, 20 ether);
        (address token, PoolKey memory key) = _launch();
        vm.warp(block.timestamp + bound(wait, 0, 600));
        _buy(key, amount);
        _sell(key, ERC20(token).balanceOf(address(this)));
        assertEq(ERC20(token).balanceOf(address(this)), 0);
    }

    receive() external payable {}
}
