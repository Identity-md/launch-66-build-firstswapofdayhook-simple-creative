// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FirstSwapOfDayHook} from "../src/FirstSwapOfDayHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract FirstSwapOfDayHookTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event FreeSwapGranted(PoolId indexed poolId, uint256 day);

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant BASE_FEE = 3_000; // 0.30%
    uint256 constant SWAP_IN = 1 ether;
    int256 constant LIQ = 1_000 ether;
    uint256 constant Q128 = 1 << 128;

    /// @dev Midnight UTC at the start of an arbitrary day (day 20_000 since the epoch).
    uint256 constant DAY0 = 20_000 days;

    /// @dev Address with exactly the afterInitialize + beforeSwap bits set.
    address constant HOOK_ADDR =
        address(uint160(0x4444 << 144) | uint160(HookFlags.AFTER_INITIALIZE | HookFlags.BEFORE_SWAP));

    PoolManager manager;
    IPoolManager pm;
    PoolSwapTest router;
    PoolSwapTest otherRouter;
    PoolModifyLiquidityTest lpRouter;
    MockERC20 token0;
    MockERC20 token1;
    FirstSwapOfDayHook hook;
    PoolKey key;
    PoolId id;

    function setUp() public {
        vm.warp(DAY0 + 12 hours);
        manager = new PoolManager(address(this));
        pm = IPoolManager(address(manager));
        router = new PoolSwapTest(manager);
        otherRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("A", "A", type(uint128).max);
        MockERC20 b = new MockERC20("B", "B", type(uint128).max);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        address[3] memory spenders = [address(router), address(otherRouter), address(lpRouter)];
        for (uint256 i = 0; i < spenders.length; i++) {
            token0.approve(spenders[i], type(uint256).max);
            token1.approve(spenders[i], type(uint256).max);
        }

        hook = _deployHook(BASE_FEE);
        key = _key(60);
        id = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);
    }

    // ---------------------------------------------------------------- helpers

    function _deployHook(uint24 baseFee) internal returns (FirstSwapOfDayHook h) {
        vm.etch(HOOK_ADDR, address(new FirstSwapOfDayHook(manager, baseFee)).code);
        h = FirstSwapOfDayHook(HOOK_ADDR);
    }

    function _key(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
    }

    function _addLiquidity(PoolKey memory k) internal {
        lpRouter.modifyLiquidity(k, ModifyLiquidityParams(-6000, 6000, LIQ, bytes32(0)), "");
    }

    function _swap(PoolSwapTest r, PoolKey memory k, bool zeroForOne, int256 amount, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        SwapParams memory p = SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        return r.swap(k, p, PoolSwapTest.TestSettings(false, false), hookData);
    }

    function _swap() internal returns (BalanceDelta) {
        return _swap(router, key, true, -int256(SWAP_IN), "");
    }

    /// @dev Total LP fees accrued so far in `k`, in token units (both directions summed), read from
    /// the pool's fee-growth accumulators. Exact enough to tell 0 from 0.30% of 1 ether.
    function _feesAccrued(PoolKey memory k) internal view returns (uint256) {
        (uint256 g0, uint256 g1) = pm.getFeeGrowthGlobals(k.toId());
        uint128 liq = pm.getLiquidity(k.toId());
        return (g0 * liq) / Q128 + (g1 * liq) / Q128;
    }

    /// @dev Fee charged by one swap: the change in accrued fees across it.
    function _feeOf(bool zeroForOne, int256 amount) internal returns (uint256 fee) {
        uint256 before = _feesAccrued(key);
        _swap(router, key, zeroForOne, amount, "");
        fee = _feesAccrued(key) - before;
    }

    function _expectedBaseFee() internal pure returns (uint256) {
        return (SWAP_IN * BASE_FEE) / 1e6;
    }

    // ------------------------------------------------------------ permissions

    function test_permissionsAreExactlyAfterInitializeAndBeforeSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.AFTER_INITIALIZE | HookFlags.BEFORE_SWAP);
    }

    function test_immutablesReflectConstruction() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.baseFee(), BASE_FEE);
    }

    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(hook).code;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    // ------------------------------------------------------------ constructor

    function test_constructor_revertsOnZeroManager() public {
        vm.expectRevert(FirstSwapOfDayHook.ZeroPoolManager.selector);
        new FirstSwapOfDayHook(IPoolManager(address(0)), BASE_FEE);
    }

    function test_constructor_revertsOnFeeAboveMax() public {
        uint24 tooBig = LPFeeLibrary.MAX_LP_FEE + 1;
        vm.expectRevert(abi.encodeWithSelector(FirstSwapOfDayHook.BaseFeeTooLarge.selector, tooBig));
        new FirstSwapOfDayHook(manager, tooBig);
    }

    function test_constructor_acceptsBoundaryFees() public {
        new FirstSwapOfDayHook(manager, 0);
        new FirstSwapOfDayHook(manager, LPFeeLibrary.MAX_LP_FEE);
    }

    // ------------------------------------------------------------ initialization

    function test_initialize_dynamicFeePoolSucceeds() public {
        PoolKey memory k = _key(10);
        manager.initialize(k, SQRT_PRICE_1_1);
        (uint160 price,,,) = pm.getSlot0(k.toId());
        assertEq(price, SQRT_PRICE_1_1);
    }

    function test_initialize_staticFeePoolReverts() public {
        PoolKey memory k = _key(10);
        k.fee = 3_000;
        vm.expectRevert(
            _wrapped(IHooks.afterInitialize.selector, FirstSwapOfDayHook.NotDynamicFeePool.selector)
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initialize_zeroFeePoolReverts() public {
        PoolKey memory k = _key(10);
        k.fee = 0;
        vm.expectRevert(
            _wrapped(IHooks.afterInitialize.selector, FirstSwapOfDayHook.NotDynamicFeePool.selector)
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initialize_maxStaticFeePoolReverts() public {
        PoolKey memory k = _key(10);
        k.fee = LPFeeLibrary.MAX_LP_FEE;
        vm.expectRevert(
            _wrapped(IHooks.afterInitialize.selector, FirstSwapOfDayHook.NotDynamicFeePool.selector)
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function _wrapped(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ---------------------------------------------------- authentication

    function test_beforeSwap_revertsWhenCalledDirectly() public {
        SwapParams memory p = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(FirstSwapOfDayHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        assertTrue(hook.freeSwapAvailable(id), "direct call must not consume the free swap");
    }

    function test_beforeSwap_revertsWhenCalledAsThePoolManagerLookalike() public {
        // Impersonating the manager's *deployer*, a router, or the hook itself gets nowhere either.
        SwapParams memory p = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        address[3] memory impostors = [address(this), address(router), address(hook)];
        for (uint256 i = 0; i < impostors.length; i++) {
            vm.prank(impostors[i]);
            vm.expectRevert(FirstSwapOfDayHook.NotPoolManager.selector);
            hook.beforeSwap(impostors[i], key, p, "");
        }
        assertTrue(hook.freeSwapAvailable(id));
    }

    function test_afterInitialize_revertsWhenCalledDirectly() public {
        vm.expectRevert(FirstSwapOfDayHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_directCallCannotPreConsumeTheFreeSwap() public {
        SwapParams memory p = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.beforeSwap, (address(this), key, p, "")));
        assertFalse(ok);
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0, "first real swap must still be free");
    }

    // ------------------------------------------------------- core behavior

    function test_firstSwapOfDayPaysZeroLpFee() public {
        assertTrue(hook.freeSwapAvailable(id));
        assertEq(hook.nextSwapFee(id), 0);
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0);
        assertEq(_feesAccrued(key), 0);
    }

    function test_secondSwapSameDayPaysBaseFee() public {
        _swap();
        assertFalse(hook.freeSwapAvailable(id));
        assertEq(hook.nextSwapFee(id), BASE_FEE);
        assertApproxEqAbs(_feeOf(true, -int256(SWAP_IN)), _expectedBaseFee(), 1e6);
    }

    function test_manySwapsSameDayAllPayBaseFee() public {
        _swap();
        for (uint256 i = 0; i < 5; i++) {
            // vary direction and time within the same day
            vm.warp(block.timestamp + 1 hours);
            assertApproxEqAbs(_feeOf(i % 2 == 0, -int256(SWAP_IN)), _expectedBaseFee(), 1e6);
        }
    }

    function test_freeSwapIsDirectionAgnostic() public {
        assertEq(_feeOf(false, -int256(SWAP_IN)), 0, "first swap, oneForZero");
        assertApproxEqAbs(_feeOf(true, -int256(SWAP_IN)), _expectedBaseFee(), 1e6, "second swap, zeroForOne");
    }

    function test_exactOutputFirstSwapIsFreeAndSecondIsNot() public {
        assertEq(_feeOf(true, int256(SWAP_IN)), 0);
        assertGt(_feeOf(true, int256(SWAP_IN)), 0);
    }

    function test_freeSwapPaysNoFeeButStillMovesThePoolAndPaysTheTrader() public {
        BalanceDelta d = _swap();
        assertEq(d.amount0(), -int128(int256(SWAP_IN)));
        assertGt(d.amount1(), 0);
        (uint160 price,,,) = pm.getSlot0(id);
        assertLt(price, SQRT_PRICE_1_1);
        // With no fee and no protocol fee, the trader gets the frictionless amount out (rounded down).
        uint128 liq = pm.getLiquidity(id);
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(SQRT_PRICE_1_1, liq, SWAP_IN, true);
        assertEq(
            uint256(uint128(d.amount1())), SqrtPriceMath.getAmount1Delta(next, SQRT_PRICE_1_1, liq, false)
        );
    }

    function test_emitsFreeSwapGrantedOnlyOnTheFirstSwap() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit FreeSwapGranted(id, DAY0 / 1 days + 1);
        _swap();

        vm.recordLogs();
        _swap();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(hook), "no free swap event on a paid swap");
        }
    }

    // ------------------------------------------------------- day rollover

    function test_nextUtcDayGrantsAnotherFreeSwap() public {
        _swap();
        _swap();
        vm.warp(DAY0 + 1 days); // exactly midnight
        assertTrue(hook.freeSwapAvailable(id));
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0, "first swap of the new day is free");
        assertApproxEqAbs(_feeOf(true, -int256(SWAP_IN)), _expectedBaseFee(), 1e6, "then base fee again");
    }

    function test_oneSecondBeforeMidnightIsStillTheSameDay() public {
        vm.warp(DAY0 + 1 days - 1);
        _swap();
        assertApproxEqAbs(_feeOf(true, -int256(SWAP_IN)), _expectedBaseFee(), 1e6);
    }

    function test_freeSwapJustBeforeMidnightThenFreeSwapAtMidnight() public {
        vm.warp(DAY0 + 1 days - 1);
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0);
        vm.warp(DAY0 + 1 days);
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0, "one second later it is a new day");
    }

    function test_freeSwapIsNotBankedAcrossIdleDays() public {
        _swap(); // day N, free
        vm.warp(DAY0 + 10 days + 5 hours);
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0, "day N+10 free");
        assertApproxEqAbs(_feeOf(true, -int256(SWAP_IN)), _expectedBaseFee(), 1e6, "but only one free swap");
    }

    function test_consecutiveDaysEachHaveExactlyOneFreeSwap() public {
        for (uint256 d = 0; d < 4; d++) {
            vm.warp(DAY0 + d * 1 days + 1 hours);
            assertEq(_feeOf(d % 2 == 0, -int256(SWAP_IN)), 0);
            assertGt(_feeOf(d % 2 == 0, -int256(SWAP_IN)), 0);
            assertGt(_feeOf(d % 2 == 0, -int256(SWAP_IN)), 0);
        }
    }

    function test_lastFreeSwapDayTracksTheDay() public {
        assertEq(hook.lastFreeSwapDay(id), 0);
        _swap();
        assertEq(hook.lastFreeSwapDay(id), DAY0 / 1 days + 1);
        assertEq(hook.currentDay(), DAY0 / 1 days + 1);
        vm.warp(DAY0 + 3 days);
        _swap();
        assertEq(hook.lastFreeSwapDay(id), DAY0 / 1 days + 4);
    }

    // ------------------------------------------- identity is never consulted

    function test_allowanceBelongsToThePoolNotTheCaller() public {
        // A different router (a different `sender` to the manager) does not get its own free swap.
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0);
        uint256 before = _feesAccrued(key);
        _swap(otherRouter, key, true, -int256(SWAP_IN), "");
        assertApproxEqAbs(_feesAccrued(key) - before, _expectedBaseFee(), 1e6);
    }

    function test_hookDataCannotClaimAFreeSwap() public {
        _swap();
        bytes[3] memory payloads = [
            abi.encode(address(0xBEEF)),
            abi.encode(address(this), uint256(1), true),
            abi.encodePacked(type(uint256).max)
        ];
        for (uint256 i = 0; i < payloads.length; i++) {
            uint256 before = _feesAccrued(key);
            _swap(router, key, true, -int256(SWAP_IN), payloads[i]);
            assertGt(_feesAccrued(key) - before, 0, "hookData must not buy a fee waiver");
        }
    }

    function test_hookDataOnTheFirstSwapChangesNothing() public {
        uint256 before = _feesAccrued(key);
        _swap(router, key, true, -int256(SWAP_IN), abi.encode(address(0xBEEF), uint256(999)));
        assertEq(_feesAccrued(key), before);
        assertFalse(hook.freeSwapAvailable(id));
    }

    // ------------------------------------------------- per-pool isolation

    function test_poolsHaveIndependentDailyAllowance() public {
        PoolKey memory kb = _key(10);
        manager.initialize(kb, SQRT_PRICE_1_1);
        _addLiquidity(kb);

        // Pool A: free then paid.
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0);
        assertGt(_feeOf(true, -int256(SWAP_IN)), 0);

        // Pool B is untouched: its first swap is still free.
        assertTrue(hook.freeSwapAvailable(kb.toId()));
        uint256 beforeB = _feesAccrued(kb);
        _swap(router, kb, true, -int256(SWAP_IN), "");
        assertEq(_feesAccrued(kb), beforeB, "pool B first swap is free");
        assertFalse(hook.freeSwapAvailable(kb.toId()));
        assertEq(hook.lastFreeSwapDay(id), hook.lastFreeSwapDay(kb.toId()));

        // Pool B's second swap pays; pool A stays paid.
        uint256 beforeB2 = _feesAccrued(kb);
        _swap(router, kb, true, -int256(SWAP_IN), "");
        assertGt(_feesAccrued(kb) - beforeB2, 0);
    }

    function test_rolloverIsPerPool() public {
        PoolKey memory kb = _key(10);
        manager.initialize(kb, SQRT_PRICE_1_1);
        _addLiquidity(kb);
        _swap();
        vm.warp(DAY0 + 1 days + 1);
        _swap(router, kb, true, -int256(SWAP_IN), "");
        // A has not used its day-2 swap, B has.
        assertTrue(hook.freeSwapAvailable(id));
        assertFalse(hook.freeSwapAvailable(kb.toId()));
    }

    // ------------------------------------------------------ failure paths

    function test_revertedSwapDoesNotConsumeTheFreeSwap() public {
        // Price limit already exceeded: reverts inside the manager, after beforeSwap ran.
        SwapParams memory bad = SwapParams(true, -int256(SWAP_IN), SQRT_PRICE_1_1 + 1);
        vm.expectRevert();
        router.swap(key, bad, PoolSwapTest.TestSettings(false, false), "");
        assertTrue(hook.freeSwapAvailable(id));
        assertEq(_feeOf(true, -int256(SWAP_IN)), 0);
    }

    function test_zeroAmountSwapCannotBurnTheFreeSwap() public {
        SwapParams memory zero = SwapParams(true, 0, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert();
        router.swap(key, zero, PoolSwapTest.TestSettings(false, false), "");
        assertTrue(hook.freeSwapAvailable(id));
    }

    function test_swapOnUninitializedPoolReverts() public {
        PoolKey memory k = _key(20);
        vm.expectRevert();
        _swap(router, k, true, -int256(SWAP_IN), "");
        assertTrue(hook.freeSwapAvailable(k.toId()));
    }

    // ----------------------------------------------- liquidity always exits

    function test_lpCanRemoveLiquidityAfterSwaps() public {
        _swap();
        _swap();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, -LIQ, bytes32(0)), "");
        assertEq(pm.getLiquidity(id), 0);
    }

    function test_lpCanAddAndRemoveOnAnyDay() public {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, 10 ether, bytes32(uint256(1))), "");
        vm.warp(DAY0 + 5 days);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, -10 ether, bytes32(uint256(1))), "");
        // and the free swap is unaffected by liquidity activity
        assertTrue(hook.freeSwapAvailable(id));
    }

    function test_lpCanRemoveLiquidityWhenPoolIsOutOfRange() public {
        // Push the price far below the range, then exit.
        _swap(router, key, true, -int256(500 ether), "");
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, -LIQ, bytes32(0)), "");
        assertEq(pm.getLiquidity(id), 0);
    }

    // ------------------------------------------------------------- fuzz

    function testFuzz_baseFeeIsWhatConstructionFixed(uint24 fee, uint128 amountIn) public {
        fee = uint24(bound(fee, 0, 100_000)); // up to 10% keeps a 1:1 pool swappable
        amountIn = uint128(bound(amountIn, 1 ether, 50 ether));
        hook = _deployHook(fee);
        PoolKey memory k = _key(30);
        manager.initialize(k, SQRT_PRICE_1_1);
        _addLiquidity(k);

        uint256 b0 = _feesAccrued(k);
        _swap(router, k, true, -int256(uint256(amountIn)), "");
        assertEq(_feesAccrued(k), b0, "free");

        assertEq(hook.nextSwapFee(k.toId()), fee);
        _swap(router, k, true, -int256(uint256(amountIn)), "");
        uint256 charged = _feesAccrued(k) - b0;
        assertApproxEqAbs(charged, (uint256(amountIn) * fee) / 1e6, 1e6);
    }

    function testFuzz_oneFreeSwapPerUtcDay(uint32[6] memory gaps) public {
        uint256 lastDay = 0;
        uint256 t = DAY0;
        for (uint256 i = 0; i < gaps.length; i++) {
            t += bound(gaps[i], 0, 3 days);
            vm.warp(t);
            uint256 day = t / 1 days;
            uint256 fee = _feeOf(i % 2 == 0, -int256(SWAP_IN));
            if (day != lastDay) {
                assertEq(fee, 0, "first swap of a new day");
                lastDay = day;
            } else {
                assertGt(fee, 0, "later swap same day");
            }
        }
    }
}
