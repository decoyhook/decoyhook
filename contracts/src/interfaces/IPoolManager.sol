// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice A v4 pool key, laid out exactly as the pool manager hashes it into a pool id.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice Swap parameters. A negative `amountSpecified` asks for an exact input.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @notice The subset of the v4 pool manager the probe calls.
interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @return swapDelta The caller's balance change, amount0 in the upper 128 bits and amount1 in the lower.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 swapDelta);

    function sync(address currency) external;

    function settle() external payable returns (uint256 paid);

    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
