// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DecoyHook} from "../hook/DecoyHook.sol";
import {LaunchToken} from "./LaunchToken.sol";

/// @title DecoyLaunchpad
/// @notice Launches a new token straight into a decoyed pool, in one transaction: it creates the
/// token, fixes the pool's rules with the hook, opens the pool against ETH and puts the supply in as
/// liquidity that holds only the token, from the start price up. That liquidity can never be
/// removed; its fees go to the launch's fee recipient. There is no owner and no upgrade path.
contract DecoyLaunchpad is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    /// @notice What a launch chooses about its pool. Fees in pips (1,000,000 is 100%), the LP share
    /// in basis points of the bite.
    struct Bait {
        uint24 baseFee;
        uint24 guardStart;
        uint32 guardSeconds;
        uint16 lpShare;
    }

    struct Launch {
        string name;
        string symbol;
        /// @dev Logo, description and links as JSON. Emitted for indexers, never stored.
        string meta;
        /// @dev The start price as the pool reads it: tokens per ETH. Rounded down to the tick spacing.
        uint160 sqrtPriceX96;
        /// @dev The share of the supply sent to the creator, in basis points, at most MAX_KEEP.
        uint16 keepBps;
        address feeRecipient;
        Bait bait;
        bytes32 salt;
    }

    struct Pool {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        address feeRecipient;
    }

    enum Action {
        Seed,
        Collect
    }

    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint16 public constant MAX_KEEP = 500;
    /// @notice The holders' share of every bite on a launched pool, in basis points.
    uint16 public constant HOLDER_SHARE = 1_500;
    int24 public constant TICK_SPACING = 60;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 1 << 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    DecoyHook public immutable hook;

    mapping(address token => Pool) internal pools;

    event Launched(address indexed token, PoolId indexed id, address indexed creator, address feeRecipient, uint256 kept, string meta);
    event Collected(address indexed token, uint256 eth, uint256 tokens);

    error NotPoolManager();
    error BadLaunch();
    error UnknownToken();

    constructor(IPoolManager manager, DecoyHook decoyHook) {
        poolManager = manager;
        hook = decoyHook;
    }

    function launch(Launch calldata l) external returns (address token, PoolId id) {
        if (l.keepBps > MAX_KEEP || l.feeRecipient == address(0) || l.bait.lpShare > BPS - HOLDER_SHARE) revert BadLaunch();
        int24 upper = _floor(TickMath.getTickAtSqrtPrice(l.sqrtPriceX96));
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        if (upper <= lower) revert BadLaunch();

        token = address(new LaunchToken{salt: _salt(msg.sender, l.salt)}(l.name, l.symbol, SUPPLY, address(this)));
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(address(hook)));
        hook.register(key, _rules(l.bait, l.feeRecipient));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(upper));
        id = key.toId();
        pools[token] = Pool(key, lower, upper, l.feeRecipient);

        uint256 kept = SUPPLY * l.keepBps / BPS;
        poolManager.unlock(abi.encode(Action.Seed, token, SUPPLY - kept));
        if (kept > 0) ERC20(token).transfer(msg.sender, kept);
        // Liquidity rounds down, so a few wei of the seed can be left over: they leave supply for good.
        uint256 dust = ERC20(token).balanceOf(address(this));
        if (dust > 0) ERC20(token).transfer(DEAD, dust);
        emit Launched(token, id, msg.sender, l.feeRecipient, kept, l.meta);
    }

    /// @notice Sends a launched pool's accrued LP fees to its fee recipient. Anyone may call it.
    function collect(address token) external returns (uint256 eth, uint256 tokens) {
        if (pools[token].feeRecipient == address(0)) revert UnknownToken();
        (eth, tokens) = abi.decode(poolManager.unlock(abi.encode(Action.Collect, token, 0)), (uint256, uint256));
        emit Collected(token, eth, tokens);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, address token, uint256 amount) = abi.decode(data, (Action, address, uint256));
        Pool storage pool = pools[token];

        if (action == Action.Seed) {
            uint160 below = TickMath.getSqrtPriceAtTick(pool.tickLower);
            uint160 top = TickMath.getSqrtPriceAtTick(pool.tickUpper);
            uint256 liquidity = FullMath.mulDiv(amount, Q96, top - below);
            (BalanceDelta delta,) = poolManager.modifyLiquidity(pool.key, _range(pool, liquidity.toInt256()), "");
            poolManager.sync(pool.key.currency1);
            ERC20(token).transfer(address(poolManager), uint128(-delta.amount1()));
            poolManager.settle();
            return "";
        }

        (BalanceDelta fees,) = poolManager.modifyLiquidity(pool.key, _range(pool, 0), "");
        uint256 eth = uint128(fees.amount0());
        uint256 tokens = uint128(fees.amount1());
        if (eth > 0) poolManager.take(pool.key.currency0, pool.feeRecipient, eth);
        if (tokens > 0) poolManager.take(pool.key.currency1, pool.feeRecipient, tokens);
        return abi.encode(eth, tokens);
    }

    function poolOf(address token) external view returns (Pool memory) {
        return pools[token];
    }

    /// @notice The address a launch will create its token at.
    function predictToken(address creator, bytes32 salt, string calldata name, string calldata symbol) external view returns (address) {
        bytes32 code = keccak256(abi.encodePacked(type(LaunchToken).creationCode, abi.encode(name, symbol, SUPPLY, address(this))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(creator, salt), code)))));
    }

    /// @dev A launch has no other pool to measure a gap against, so its pool runs the launch guard and
    /// the base fee only: the reference is a pool id no pool can have.
    function _rules(Bait calldata bait, address feeRecipient) internal pure returns (DecoyHook.Rules memory) {
        return DecoyHook.Rules({
            baseFee: bait.baseFee,
            deadBand: 0,
            cap: bait.baseFee,
            guardStart: bait.guardStart,
            guardSeconds: bait.guardSeconds,
            capture: 0,
            lpShare: bait.lpShare,
            teamShare: uint16(BPS - HOLDER_SHARE - bait.lpShare),
            holderShare: HOLDER_SHARE,
            tokenIsCurrency0: false,
            team: feeRecipient,
            refPool: PoolId.wrap(bytes32(0))
        });
    }

    function _range(Pool storage pool, int256 liquidity) internal view returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({tickLower: pool.tickLower, tickUpper: pool.tickUpper, liquidityDelta: liquidity, salt: 0});
    }

    function _salt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    function _floor(int24 tick) internal pure returns (int24) {
        int24 rounded = tick / TICK_SPACING * TICK_SPACING;
        return rounded > tick ? rounded - TICK_SPACING : rounded;
    }
}
