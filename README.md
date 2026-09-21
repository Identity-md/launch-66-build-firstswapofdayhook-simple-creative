# FirstSwapOfDayHook

A small Uniswap v4 dynamic-fee hook. In each pool that uses it, **the first swap of each UTC day pays a
zero LP fee; every later swap that day pays the base fee fixed at construction.**

Source and tests only. There is no token, no deployment script, no launch manifest, and no frontend.
This is not an audit; see [Risks](#risks-and-known-properties).

## Behaviour

| Swap                                   | LP fee paid          |
| -------------------------------------- | -------------------- |
| First swap in a pool on a UTC day      | `0`                  |
| Any later swap in that pool that day   | `baseFee`            |
| First swap after UTC midnight          | `0` again, then `baseFee` |

- **Day** is `block.timestamp / 1 days` (UTC midnight to midnight). `currentDay()` returns that plus 1, so
  `0` in storage always means "never".
- **Per pool.** State is `mapping(PoolId => uint256 lastFreeDay)`. One pool's swaps never touch another
  pool's allowance, even though they share the hook contract.
- **Not banked.** Idle days do not accumulate free swaps; a pool gets at most one per day.
- **Direction and size agnostic.** Either direction, exact-in or exact-out, any size.
- **Reverts roll back.** A swap that reverts (bad price limit, no liquidity, zero amount) does not consume the day's free swap.
- The fee is applied with `beforeSwap`'s fee override (`baseFee | OVERRIDE_FEE_FLAG`). The hook never
  returns a swap delta and never holds funds.

## Security model

- **Callbacks are authenticated.** `afterInitialize` and `beforeSwap` revert `NotPoolManager` unless
  `msg.sender` equals the `poolManager` immutable given at construction.
- **No identity is trusted.** `sender` and `hookData` are ignored entirely. The free swap belongs to the pool,
  not to an account, router, or `hookData` claim. Any caller can take it and no caller can take more than one.
- **Dynamic-fee validation at `afterInitialize`.** Pool initialization reverts (`NotDynamicFeePool`, wrapped
  by the manager) unless `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG`. Without the flag the manager would ignore
  the fee override and the pool would silently never grant a free swap.
- **LP exits are never blocked.** No liquidity, donate, or `afterSwap` permission is enabled, so add/remove
  liquidity never enters the hook.
- **No owner, no admin, no upgrade path.** `baseFee` and `poolManager` are immutables. The runtime code has no
  `DELEGATECALL`, `CALLCODE`, or `SELFDESTRUCT` (checked by a test).
- **Permissions:** exactly `afterInitialize` and `beforeSwap`. No return-delta permissions.

## Layout

```
src/FirstSwapOfDayHook.sol   the hook
src/HookFlags.sol            permission-bit constants and address checks (dependency-free)
test/FirstSwapOfDayHook.t.sol   tests against a real v4-core PoolManager, PoolSwapTest, PoolModifyLiquidityTest
test/mocks/MockERC20.sol     test token
lib/                         vendored dependencies (ordinary files, no submodules)
foundry.toml
```

## Deployment parameters and assumptions

Nothing here deploys anything. Whoever deploys is responsible for:

1. **`_poolManager`**: the canonical `PoolManager` of the target chain. It is immutable; a wrong address
   yields a hook that no manager can call. The hook does not verify it is a real manager.
2. **`_baseFee`**: hundredths of a bip (`3000` = 0.30%), at most `LPFeeLibrary.MAX_LP_FEE` (`1_000_000`);
   otherwise the constructor reverts. The value cannot change afterwards, and it applies to every pool that
   uses this hook instance. Deploy another instance for a different base fee.
3. **Address mining.** The v4 manager reads permissions from the hook address. The address must have
   exactly bits `AFTER_INITIALIZE (1<<12) | BEFORE_SWAP (1<<7)` = `0x1080` in its low 14 bits (mine a CREATE2
   salt; `HookFlags.matches` checks this). The hook is deployed with constructor args, so the salt search
   depends on them.
4. **Pool creation.** Pools must be initialized with `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`) and
   `hooks = <hook address>`. Any other fee value makes `initialize` revert.
5. **Time source.** `block.timestamp`. The chain's timestamp semantics (e.g. L2 sequencer timestamps)
   determine when "midnight" is observed.
6. **Verification before use.** Run the fork rehearsal against the target chain's real manager, and get an
   independent review before the hook carries meaningful liquidity.

## Operational responsibilities

There is no administrator. Operators are responsible only for: choosing and communicating `baseFee`,
mining/deploying at a correctly-flagged address, initializing pools with the dynamic flag, and monitoring
the `FreeSwapGranted(poolId, day)` event. Frontends should call `freeSwapAvailable(poolId)` /
`nextSwapFee(poolId)` to quote the fee, remembering the answer can change between quote and inclusion.

## Risks and known properties

- **First-swap gaming is inherent.** The free swap is open to anyone and any size. A large trader can wait
  for a day's first swap and pay no LP fee; a dust swap (a few wei) can burn the day's free swap, so
  ordinary users pay `baseFee` all day. LPs give up fee revenue on the day's first swap. This is the named
  design, not a bug, but pools using it should expect the free swap to be taken by whoever is most
  motivated (and sophisticated searchers can take it at the very start of each day).
- **Same-transaction ordering.** Within one transaction the first swap is free and the rest pay `baseFee`;
  a router that batches swaps gets one free swap for the batch.
- **Timestamp granularity.** Block producers can shift `block.timestamp` slightly, which can move a swap
  across midnight by seconds (or a few minutes on some chains). No value is derived from it beyond the day
  boundary; it is not used for randomness.
- **Protocol fee is separate.** The zero fee is the *LP* fee. Any protocol fee configured on the pool manager
  still applies.
- **A pool with zero liquidity at the free swap** simply reverts; the swap is rolled back and the free swap
  is retained.
- **No timelock or pause** exists because there is nothing to pause; conversely a mistake in `baseFee` or
  the manager address is fixed by deploying a new instance and new pools.

## Testing

```
forge build
forge test
forge fmt --check
```

`test/FirstSwapOfDayHook.t.sol` runs against a real, freshly deployed `PoolManager` (initialize, add
liquidity, swap through `PoolSwapTest`, remove liquidity through `PoolModifyLiquidityTest`). Fee charged is
measured from the pool's `feeGrowthGlobal` accumulators rather than assumed. Covered: permissions/address bits,
constructor bounds, dynamic-fee validation (static, zero, and max static fee revert), caller authentication
(direct calls, impostor addresses, cannot pre-consume the free swap), free-then-paid within a day, both directions,
exact-in and exact-out, midnight boundary (one second before/at), multi-day gaps, per-pool isolation and
rollover, different routers and arbitrary `hookData`, reverted swaps, LP add/remove including out-of-range,
and fuzzing over base fee, swap size, and timestamps. Tests do not substitute for an audit.

## Vendored dependencies

Copied as ordinary files under `lib/` (no submodules; builds and tests run offline). Solidity `0.8.26`,
EVM `cancun`, `via_ir`.

| Path            | Upstream                                | Pin                                        |
| --------------- | --------------------------------------- | ------------------------------------------ |
| `lib/v4-core`   | https://github.com/Uniswap/v4-core      | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` (`src/`, plus `test/utils/CurrencySettler.sol`) |
| `lib/solmate`   | https://github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` (`src/`) |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | `1de6eecf821de7fe2c908cc48d3ab3dced20717f` (`src/`) |

v4-core is used as-is at a post-`v4.0.0` commit (the first to contain `types/PoolOperation.sol`); its
licenses (BUSL-1.1 for core contracts, MIT for interfaces/libraries as marked per file) are in
`lib/v4-core/licenses/`. Files in this repo's `src/` and `test/` are MIT.
