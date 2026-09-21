// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title FirstSwapOfDayHook
/// @notice Dynamic-fee hook: the first swap in a pool on each UTC day pays a zero LP fee, every later
/// swap that day pays the base fee fixed at construction.
/// @dev Permissions: `afterInitialize` (require a dynamic-fee pool) and `beforeSwap` (override the LP fee).
/// The hook never returns a swap delta, never touches liquidity callbacks, holds no funds, has no owner and
/// no upgrade path. Identity is deliberately absent: `sender` and `hookData` are ignored, so the daily free
/// swap belongs to the pool, not to an account.
contract FirstSwapOfDayHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    /// @notice A callback was invoked by an address other than the canonical pool manager.
    error NotPoolManager();
    /// @notice The pool being initialized does not carry `LPFeeLibrary.DYNAMIC_FEE_FLAG`.
    error NotDynamicFeePool();
    /// @notice The constructor was given a zero pool manager.
    error ZeroPoolManager();
    /// @notice The constructor was given a base fee above `LPFeeLibrary.MAX_LP_FEE`.
    error BaseFeeTooLarge(uint24 baseFee);

    /// @notice A pool's daily zero-fee swap was granted.
    /// @param poolId The pool.
    /// @param day The UTC day counter (see `currentDay`).
    event FreeSwapGranted(PoolId indexed poolId, uint256 day);

    uint256 internal constant SECONDS_PER_DAY = 1 days;

    /// @notice The canonical pool manager; the only address allowed to call the callbacks.
    IPoolManager public immutable poolManager;

    /// @notice LP fee (hundredths of a bip) charged on every swap after the day's first.
    uint24 public immutable baseFee;

    /// @dev Day counter (`currentDay`) of each pool's most recent free swap; 0 means never.
    mapping(PoolId => uint256) internal _lastFreeDay;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The canonical v4 `PoolManager`.
    /// @param _baseFee LP fee for non-first swaps, in hundredths of a bip (3000 = 0.30%).
    constructor(IPoolManager _poolManager, uint24 _baseFee) {
        if (address(_poolManager) == address(0)) revert ZeroPoolManager();
        if (!_baseFee.isValid()) revert BaseFeeTooLarge(_baseFee);
        poolManager = _poolManager;
        baseFee = _baseFee;
    }

    /// @notice The permissions this hook's address must be mined for.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Rejects any pool that is not a dynamic-fee pool; without the flag the fee override in
    /// `beforeSwap` would be silently ignored and the pool would never grant its free swap.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
        return this.afterInitialize.selector;
    }

    /// @notice Charges zero LP fee on the first swap of the UTC day in this pool and `baseFee` afterwards.
    /// @dev `sender` and `hookData` are unused on purpose. The pool is identified by `key`, which the
    /// manager derived from its own storage lookup of a pool that named this hook.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint256 day = currentDay();

        uint24 fee = baseFee;
        if (_lastFreeDay[id] != day) {
            _lastFreeDay[id] = day;
            fee = 0;
            emit FreeSwapGranted(id, day);
        }

        return
            (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    /// @notice The current UTC day, counted from 1 on 1970-01-01 (so 0 is never a real day).
    function currentDay() public view returns (uint256) {
        return block.timestamp / SECONDS_PER_DAY + 1;
    }

    /// @notice Whether the next swap in `poolId` would be the free one.
    function freeSwapAvailable(PoolId poolId) external view returns (bool) {
        return _lastFreeDay[poolId] != currentDay();
    }

    /// @notice The UTC day counter of `poolId`'s latest free swap, or 0 if it has never had one.
    function lastFreeSwapDay(PoolId poolId) external view returns (uint256) {
        return _lastFreeDay[poolId];
    }

    /// @notice The LP fee the next swap in `poolId` would pay.
    function nextSwapFee(PoolId poolId) external view returns (uint24) {
        return _lastFreeDay[poolId] != currentDay() ? 0 : baseFee;
    }
}
