# Uniswap v4 Developer Feedback

Notes from building the Reopen Auction Hook during the hackathon. Each item is something we actually hit.

## What worked well

- **Hooks skip their own calls.** When the hook calls `PoolManager.swap` / `donate` from its own `unlockCallback`,
  v4 skips that hook's own callbacks (`noSelfCall` in `Hooks.sol`). That made it easy to lock a pool for
  everyone except the auction winner. It is the core of this design, and it's worth documenting prominently.
- **`donate` makes paying LPs trivial.** Sending the winning bid to in-range LPs is one call. It shows up as
  ordinary fees on `collect`, with no custom accounting.
- **Flash accounting + `TransientStateLibrary.currencyDelta`.** Doing swap + donate, then settling the net delta
  per currency with the bidder, kept the callback short and correct.
- **OpenZeppelin `uniswap-hooks` `BaseHook` and `CurrencySettler`** removed a lot of boilerplate.

## Friction

1. **Wrapped hook reverts make `expectRevert` awkward.** A hook revert comes back as
   `WrappedError(hook, selector, reason, HookCallFailed())`. Matching it in Foundry means rebuilding the whole
   encoded error by hand. A test helper in v4-core (e.g. `expectHookRevert(hook, selector, reason)`) would help.
2. **v4-template submodules can come up empty.** `lib/uniswap-hooks/lib/v4-periphery/lib/permit2` was initialized
   but had no files, so `forge build` failed on `permit2/src/interfaces/IPermit2.sol`. We needed a manual
   `git checkout -f` inside the nested submodule.
3. **Template scripts don't work for real deploys out of the box.**
   - `EasyPosm.mint` reads `balanceOf(address(this))`, and Foundry rejects `address(this)` in scripts. We had
     to encode `MINT_POSITION` / `SETTLE_PAIR` by hand.
   - On anvil, `anvil_setCode` for Permit2 doesn't reach the script's local simulation, so the next call reverts
     with "call to non-contract". We needed a `vm.etch` alongside the RPC call.
   - `BaseScript` hardcodes token addresses. Multi-pool projects need a config-driven base.
4. **Cheatcodes consumed by hidden external calls.** Helpers that read `StateLibrary.getSlot0` (an `extsload`
   call) between `vm.prank` / `vm.expectRevert` and the target call silently use up the cheatcode. This is
   Foundry behaviour, but it is easy to hit with v4 because pool reads are external calls. Worth a note in the docs.
5. **No helper for "price → sqrtPriceX96 with decimals."** Every project rewrites
   `sqrt(price · 10^d1 / 10^d0 · 2^192)`. A small library in v4-periphery would prevent decimal bugs.
6. **Hook permissions vs address mining.** Mining a salt is fine, but deploy failures from a flags mismatch are
   opaque (`HookAddressNotValid`). An error that says which flag bits are missing or extra would save time.

## Wishlist

- A documented pattern for "pool phases" (locked / auction / open). Several MEV-aware hook designs need it.
- First-class guidance on JIT protection around `donate` (we block `beforeAddLiquidity` during the auction).
- Testnet faucet tokens for tokenized-equity-style pairs (6/8/18-decimal mixes) to demo multi-pair hooks.
