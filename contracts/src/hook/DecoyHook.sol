// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title DecoyHook
/// @notice A bait hook for v4 pools. A swap that closes a price gap with the pool's reference pays a
/// fee sized to that gap, and buys in the first moments after the pool opens pay a launch guard that
/// falls to the base fee. Everything above the base fee is the bite. The LPs' share of the bite stays
/// in the pool as fees; the team's and the holders' shares are taken by the hook and paid out on
/// request. Each pool's rules are fixed when it opens. There is no owner and no upgrade path.
contract DecoyHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    /// @notice A pool's rules. Fees in pips (1,000,000 is 100%), shares and capture in basis points.
    struct Rules {
        uint24 baseFee;
        uint24 deadBand;
        uint24 cap;
        uint24 guardStart;
        uint32 guardSeconds;
        uint16 capture;
        uint16 lpShare;
        uint16 teamShare;
        uint16 holderShare;
        bool tokenIsCurrency0;
        address team;
        PoolId refPool;
    }

    /// @notice A price read from the reference pool, and the chain block it was read in.
    struct Snapshot {
        uint160 sqrtPriceX96;
        uint64 blockNumber;
    }

    struct Pool {
        Rules rules;
        uint64 openedAt;
        Snapshot used;
        Snapshot fresh;
    }

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant Q96 = 1 << 96;
    uint24 public constant MAX_BASE_FEE = 10_000;
    uint24 public constant MAX_CAP = 100_000;
    uint24 public constant MAX_GUARD = 500_000;
    uint32 public constant MAX_GUARD_SECONDS = 600;
    uint16 public constant MAX_HOLDER_SHARE = 4_000;
    /// @notice A reference older than this many blocks (about a minute at 100 ms) is not used.
    uint64 public constant MAX_REFERENCE_AGE = 600;
    /// @dev The chain's own block number. `block.number` on this chain is an estimate of the parent
    /// chain's block and moves too slowly to order anything.
    address internal constant ARB_SYS = address(100);

    IPoolManager public immutable poolManager;
    /// @notice Where the holders' share of every bite goes.
    address public immutable vault;

    mapping(PoolId => mapping(address registrar => Rules)) internal pending;
    mapping(PoolId => Pool) internal pools;
    mapping(address team => mapping(Currency => uint256)) public teamOwed;
    mapping(Currency => uint256) public vaultOwed;

    /// @dev The part of the current swap's bite the hook takes, from beforeSwap to afterSwap.
    uint24 private transient takePips;

    event Registered(PoolId indexed id, address indexed registrar, address team);
    event Opened(PoolId indexed id, address indexed registrar);
    event Bite(PoolId indexed id, Currency currency, uint256 taken, uint256 toTeam);
    event Claimed(address indexed team, Currency currency, uint256 amount);
    event Swept(Currency currency, uint256 amount);

    error NotPoolManager();
    error WrongHook();
    error NotDynamicFee();
    error AlreadyOpen();
    error NotRegistered();
    error BadRules();
    error NothingOwed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager manager, address holderVault) {
        if (holderVault == address(0)) revert BadRules();
        poolManager = manager;
        vault = holderVault;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }


    /// @notice Registers the rules for a pool before it opens. Only the same caller can then open the
    /// pool with them, so nobody can register rules for someone else's launch.
    function register(PoolKey calldata key, Rules calldata rules) external {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert NotDynamicFee();
        PoolId id = key.toId();
        if (pools[id].openedAt != 0) revert AlreadyOpen();
        if (!_valid(rules, id)) revert BadRules();
        pending[id][msg.sender] = rules;
        emit Registered(id, msg.sender, rules.team);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        Rules memory rules = pending[id][sender];
        if (rules.team == address(0)) revert NotRegistered();
        delete pending[id][sender];
        Pool storage pool = pools[id];
        pool.rules = rules;
        pool.openedAt = uint64(block.timestamp);
        _refresh(pool);
        emit Opened(id, sender);
        return this.beforeInitialize.selector;
    }

    /// @notice Reads the reference price for later blocks. Anyone may call it; it can only make the
    /// reference fresher.
    function poke(PoolKey calldata key) external {
        Pool storage pool = pools[key.toId()];
        if (pool.openedAt == 0) revert NotRegistered();
        _roll(pool);
        _refresh(pool);
    }


    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Pool storage pool = pools[key.toId()];
        _roll(pool);
        (uint24 lpFee, uint24 take,) = _fees(key, pool, params.zeroForOne);
        takePips = take;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        uint24 pips = takePips;
        takePips = 0;
        PoolId id = key.toId();
        Pool storage pool = pools[id];
        _refresh(pool);
        if (pips == 0) return (this.afterSwap.selector, 0);

        // The hook's share is charged on the side the swapper did not fix: the output of an exact-in
        // swap, the input of an exact-out swap. Either way the quote already includes it.
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        (Currency currency, int128 amount) = specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        uint256 size = uint256(uint128(amount < 0 ? -amount : amount));
        uint256 taken = FullMath.mulDiv(size, pips, PIPS);
        if (taken == 0) return (this.afterSwap.selector, 0);

        poolManager.mint(address(this), currency.toId(), taken);
        Rules storage rules = pool.rules;
        uint256 toTeam = taken * rules.teamShare / (uint256(rules.teamShare) + rules.holderShare);
        teamOwed[rules.team][currency] += toTeam;
        vaultOwed[currency] += taken - toTeam;
        emit Bite(id, currency, taken, toTeam);
        return (this.afterSwap.selector, taken.toInt128());
    }


    /// @notice Pays the caller everything its pools have earned in one currency.
    function claim(Currency currency) external returns (uint256 amount) {
        amount = teamOwed[msg.sender][currency];
        if (amount == 0) revert NothingOwed();
        teamOwed[msg.sender][currency] = 0;
        emit Claimed(msg.sender, currency, amount);
        poolManager.unlock(abi.encode(currency, msg.sender, amount));
    }

    /// @notice Sends the holders' share in one currency to the vault. Anyone may call it.
    function sweep(Currency currency) external returns (uint256 amount) {
        amount = vaultOwed[currency];
        if (amount == 0) revert NothingOwed();
        vaultOwed[currency] = 0;
        emit Swept(currency, amount);
        poolManager.unlock(abi.encode(currency, vault, amount));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        return "";
    }


    function rulesOf(PoolId id) external view returns (Rules memory) {
        return pools[id].rules;
    }

    /// @notice What a swap in this direction would pay now: the LP fee, the hook's take and the gap,
    /// all in pips. The same numbers a quote sees.
    function quoteFees(PoolKey calldata key, bool zeroForOne) external view returns (uint24 lpFee, uint24 take, uint24 gap) {
        Pool storage pool = pools[key.toId()];
        Snapshot memory ref = _usable(pool);
        return _feesWith(key, pool, zeroForOne, ref);
    }


    function _fees(PoolKey calldata key, Pool storage pool, bool zeroForOne) internal view returns (uint24, uint24, uint24) {
        return _feesWith(key, pool, zeroForOne, _usable(pool));
    }

    function _feesWith(PoolKey calldata key, Pool storage pool, bool zeroForOne, Snapshot memory ref)
        internal
        view
        returns (uint24 lpFee, uint24 take, uint24 gap)
    {
        Rules storage rules = pool.rules;
        uint256 base = rules.baseFee;
        uint256 fee = base;

        if (ref.sqrtPriceX96 != 0) {
            (uint160 current,,,) = poolManager.getSlot0(key.toId());
            bool closing;
            (gap, closing) = _gap(current, ref.sqrtPriceX96, zeroForOne);
            if (closing && gap > rules.deadBand) {
                uint256 gapFee = base + (uint256(gap) - rules.deadBand) * rules.capture / BPS;
                if (gapFee > rules.cap) gapFee = rules.cap;
                if (gapFee > fee) fee = gapFee;
            }
        }

        uint256 ends = uint256(pool.openedAt) + rules.guardSeconds;
        bool buy = rules.tokenIsCurrency0 ? !zeroForOne : zeroForOne;
        if (buy && block.timestamp < ends && rules.guardStart > base) {
            uint256 guardFee = base + (uint256(rules.guardStart) - base) * (ends - block.timestamp) / rules.guardSeconds;
            if (guardFee > fee) fee = guardFee;
        }

        uint256 bite = fee - base;
        uint256 lpPart = bite * rules.lpShare / BPS;
        lpFee = uint24(base + lpPart);
        take = uint24(bite - lpPart);
    }

    /// @dev The gap in pips between the pool and the reference, and whether this direction closes it.
    function _gap(uint160 current, uint160 refPrice, bool zeroForOne) internal pure returns (uint24 gap, bool closing) {
        if (current == refPrice) return (0, false);
        // A swap from currency0 to currency1 lowers the price; it closes a gap where the pool is above.
        closing = current > refPrice ? zeroForOne : !zeroForOne;
        uint256 ratio = FullMath.mulDiv(current, Q96, refPrice);
        if (ratio >= 2 * Q96 || ratio <= Q96 / 2) return (uint24(PIPS), closing);
        uint256 price = FullMath.mulDiv(ratio, ratio, Q96);
        uint256 off = price > Q96 ? price - Q96 : Q96 - price;
        uint256 pips = FullMath.mulDiv(off, PIPS, Q96);
        gap = uint24(pips > PIPS ? PIPS : pips);
    }

    /// @dev The reference a swap may use: read in an earlier block, and not too old.
    function _usable(Pool storage pool) internal view returns (Snapshot memory) {
        uint64 now_ = _blockNumber();
        Snapshot memory used = pool.fresh.blockNumber != 0 && pool.fresh.blockNumber < now_ ? pool.fresh : pool.used;
        if (used.blockNumber == 0 || used.blockNumber >= now_ || now_ - used.blockNumber > MAX_REFERENCE_AGE) {
            return Snapshot(0, 0);
        }
        return used;
    }

    /// @dev Once a new block starts, the last fresh read becomes the one swaps use.
    function _roll(Pool storage pool) internal {
        uint64 fresh = pool.fresh.blockNumber;
        if (fresh != 0 && fresh < _blockNumber()) pool.used = pool.fresh;
    }

    /// @dev Reads the reference pool now. Swaps only see this read from the next block on.
    function _refresh(Pool storage pool) internal {
        (uint160 price,,,) = poolManager.getSlot0(pool.rules.refPool);
        if (price == 0) return;
        pool.fresh = Snapshot(price, _blockNumber());
    }

    function _blockNumber() internal view returns (uint64) {
        (bool ok, bytes memory data) = ARB_SYS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        if (ok && data.length == 32) return uint64(abi.decode(data, (uint256)));
        return uint64(block.number);
    }

    function _valid(Rules calldata rules, PoolId id) internal pure returns (bool) {
        return rules.team != address(0) && PoolId.unwrap(rules.refPool) != PoolId.unwrap(id)
            && uint256(rules.lpShare) + rules.teamShare + rules.holderShare == BPS && rules.holderShare <= MAX_HOLDER_SHARE
            && rules.baseFee <= MAX_BASE_FEE && rules.cap >= rules.baseFee && rules.cap <= MAX_CAP && rules.deadBand <= rules.cap
            && rules.capture <= BPS && rules.guardStart <= MAX_GUARD && rules.guardSeconds <= MAX_GUARD_SECONDS
            && (rules.guardStart <= rules.baseFee || rules.guardSeconds > 0);
    }
}
