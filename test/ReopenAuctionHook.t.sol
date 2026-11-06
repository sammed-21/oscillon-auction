// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {AuctionFixture} from "./utils/AuctionFixture.sol";
import {ReopenAuctionHook} from "../src/ReopenAuctionHook.sol";

/// Scenes:
///   1. Market open: the pool behaves like a normal pool.
///   2. Reopen: the keeper starts the auction; public swaps and LP adds revert; price falls block by block.
///   3. Win: the bidder pays the Dutch price, arbs to the ref price, the bid lands with LPs, the pool reopens.
///   4. Edge cases: no bid (auction expires), maxBid guard, access control, cancel.
///   Multi-pool: one hook runs independent auctions on pools with different decimals, prices, fees and gaps.
contract ReopenAuctionHookTest is AuctionFixture {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    uint256 constant INITIAL_PRICE = 180e18; // currency1 per currency0 at market close
    uint256 constant REF_PRICE = 190e18; // first print at market reopen

    PoolInfo pool; // the default pool used by scenes 1-4

    function setUp() public {
        _deployHook();
        pool = _createPool(defaultPair(INITIAL_PRICE));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _wrappedHookRevert(bytes4 hookSelector) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            abi.encodeWithSelector(ReopenAuctionHook.AuctionActive.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _publicSwap(PoolInfo memory p, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        vm.prank(trader);
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: p.key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        });
    }

    /// @dev External so `expectRevert` covers the whole mint (EasyPosm makes calls before the revert).
    function addFullRangeLiquidity(PoolInfo memory p, uint128 liquidity) external {
        positionManager.mint(
            p.key,
            TickMath.minUsableTick(p.key.tickSpacing),
            TickMath.maxUsableTick(p.key.tickSpacing),
            liquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function _startAuction(PoolInfo memory p, uint256 refPrice) internal returns (uint256 startBid) {
        uint160 ref = toSqrtPriceX96(p, refPrice);
        vm.prank(keeper);
        startBid = hook.startAuction(p.key, ref);
    }

    function _bid(PoolInfo memory p, uint256 refPrice, uint256 maxBid)
        internal
        returns (BalanceDelta swapDelta, uint256 bid)
    {
        SwapParams memory params = arbParams(p, toSqrtPriceX96(p, refPrice));
        vm.prank(bidder);
        (swapDelta, bid) = hook.bidAndSwap(p.key, params, maxBid);
    }

    function _assertOpen(PoolInfo memory p) internal view {
        assertEq(uint8(hook.phase(p.id)), uint8(ReopenAuctionHook.Phase.OPEN));
    }

    function _assertAuction(PoolInfo memory p) internal view {
        assertEq(uint8(hook.phase(p.id)), uint8(ReopenAuctionHook.Phase.AUCTION));
    }

    /// @dev Full winning path on `p`: bid, then check price, bidder P&L and LP payout.
    function _winAndCheck(PoolInfo memory p, uint256 refPrice) internal returns (uint256 bid) {
        uint160 ref = toSqrtPriceX96(p, refPrice);
        bool bidIn0 = hook.bidInCurrency0(p.id);

        uint256 b0 = p.key.currency0.balanceOf(bidder);
        uint256 b1 = p.key.currency1.balanceOf(bidder);

        BalanceDelta swapDelta;
        (swapDelta, bid) = _bid(p, refPrice, type(uint256).max);
        assertGt(bid, 0, "bid");

        // Pool lands exactly on the reference price and reopens.
        assertEq(sqrtPriceOf(p), ref, "price at ref");
        _assertOpen(p);

        // Bidder paid swap input + bid, and still profits when marked at the reference price.
        int256 d0 = int256(p.key.currency0.balanceOf(bidder)) - int256(b0);
        int256 d1 = int256(p.key.currency1.balanceOf(bidder)) - int256(b1);
        assertEq(d0, int256(swapDelta.amount0()) - (bidIn0 ? int256(bid) : int256(0)), "bidder d0");
        assertEq(d1, int256(swapDelta.amount1()) - (bidIn0 ? int256(0) : int256(bid)), "bidder d1");
        assertGt(valueIn1(d0, d1, ref), 0, "bidder profit");

        // LPs collect at least the bid in the bid currency.
        BalanceDelta fees = positionManager.collect(p.lpTokenId, 0, 0, address(this), block.timestamp, "");
        uint256 collected = uint256(int256(bidIn0 ? fees.amount0() : fees.amount1()));
        assertGe(collected + 1, bid, "LP payout");
    }

    // ------------------------------------------------------------------
    // Scene 1: market open
    // ------------------------------------------------------------------

    function test_scene1_openMarketSwapsNormally() public {
        _assertOpen(pool);
        BalanceDelta d = _publicSwap(pool, true, 1e18);
        assertEq(d.amount0(), -1e18);
        assertGt(d.amount1(), 0);
    }

    // ------------------------------------------------------------------
    // Scene 2: reopen locks the pool
    // ------------------------------------------------------------------

    function test_scene2_startAuctionLocksPool() public {
        uint160 ref = toSqrtPriceX96(pool, REF_PRICE);
        uint256 estimate = hook.estimateArbProfit(pool.key, ref);
        uint256 startBid = _startAuction(pool, REF_PRICE);

        assertEq(startBid, estimate * PREMIUM_BPS / 10_000);
        _assertAuction(pool);

        vm.expectRevert(_wrappedHookRevert(IHooks.beforeSwap.selector));
        _publicSwap(pool, false, 1000e18);

        // JIT liquidity is blocked.
        vm.expectRevert(_wrappedHookRevert(IHooks.beforeAddLiquidity.selector));
        this.addFullRangeLiquidity(pool, 1e18);

        // Cannot start a second auction on top.
        vm.prank(keeper);
        vm.expectRevert(ReopenAuctionHook.AuctionActive.selector);
        hook.startAuction(pool.key, ref);
    }

    function test_scene2_priceFallsBlockByBlock() public {
        uint256 startBid = _startAuction(pool, REF_PRICE);
        uint256 last = hook.currentPrice(pool.id);
        assertEq(last, startBid);
        for (uint256 i = 1; i <= AUCTION_BLOCKS; i++) {
            vm.roll(block.number + 1);
            uint256 p = hook.currentPrice(pool.id);
            assertLt(p, last);
            assertEq(p, startBid * (AUCTION_BLOCKS - i) / AUCTION_BLOCKS);
            last = p;
        }
        assertEq(last, 0);
    }

    // ------------------------------------------------------------------
    // Scene 3: the winner arbs, LPs get the bid
    // ------------------------------------------------------------------

    function test_scene3_winnerArbsAndBidGoesToLPs() public {
        _startAuction(pool, REF_PRICE);
        // At 1.5x the fee-free estimate, the first blocks are unprofitable once the swap fee is paid.
        // A rational bidder waits until the price drops below its real profit: block 5 = 50% of start.
        vm.roll(block.number + 5);
        uint256 price = hook.currentPrice(pool.id);
        uint256 bid = _winAndCheck(pool, REF_PRICE);
        assertEq(bid, price);
        _publicSwap(pool, true, 1e18);
    }

    function test_scene3_estimateMatchesRealizedArb() public {
        // Gross arb (after fee, before bid) + swap fee ~= on-chain estimate for a full-range pool.
        uint160 ref = toSqrtPriceX96(pool, REF_PRICE);
        uint256 estimate = hook.estimateArbProfit(pool.key, ref);
        _startAuction(pool, REF_PRICE);
        vm.roll(block.number + AUCTION_BLOCKS); // price 0, isolate the swap
        (BalanceDelta d, uint256 bid) = _bid(pool, REF_PRICE, type(uint256).max);
        assertEq(bid, 0);
        uint256 fee = uint256(-int256(d.amount1())) * DEFAULT_FEE / 1e6;
        int256 gross = valueIn1(d.amount0(), d.amount1(), ref);
        assertApproxEqRel(uint256(gross) + fee, estimate, 0.01e18);
    }

    function test_scene3_priceDownGap() public {
        assertGt(_startAuction(pool, 170e18), 0);
        vm.roll(block.number + 6);
        _winAndCheck(pool, 170e18);
    }

    // ------------------------------------------------------------------
    // Scene 4: edge cases
    // ------------------------------------------------------------------

    function test_scene4_noBidPoolReopensAfterExpiry() public {
        _startAuction(pool, REF_PRICE);
        vm.roll(block.number + AUCTION_BLOCKS + 1);
        _assertOpen(pool);
        assertEq(hook.currentPrice(pool.id), 0);
        _publicSwap(pool, false, 1000e18);

        SwapParams memory params = arbParams(pool, toSqrtPriceX96(pool, REF_PRICE));
        vm.prank(bidder);
        vm.expectRevert(ReopenAuctionHook.NoActiveAuction.selector);
        hook.bidAndSwap(pool.key, params, type(uint256).max);
    }

    function test_scene4_maxBidGuard() public {
        uint256 startBid = _startAuction(pool, REF_PRICE);
        SwapParams memory params = arbParams(pool, toSqrtPriceX96(pool, REF_PRICE));
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(ReopenAuctionHook.BidTooHigh.selector, startBid, startBid - 1));
        hook.bidAndSwap(pool.key, params, startBid - 1);
    }

    function test_scene4_onlyKeeperStarts() public {
        uint160 ref = toSqrtPriceX96(pool, REF_PRICE);
        vm.prank(trader);
        vm.expectRevert(ReopenAuctionHook.NotKeeper.selector);
        hook.startAuction(pool.key, ref);
    }

    function test_scene4_ownerCancelReopens() public {
        _startAuction(pool, REF_PRICE);
        hook.cancelAuction(pool.key);
        _assertOpen(pool);
        _publicSwap(pool, true, 1e18);
    }

    function test_scene4_secondBidderLoses() public {
        _startAuction(pool, REF_PRICE);
        _bid(pool, REF_PRICE, type(uint256).max);

        SwapParams memory params = arbParams(pool, toSqrtPriceX96(pool, REF_PRICE));
        vm.prank(trader);
        vm.expectRevert(ReopenAuctionHook.NoActiveAuction.selector);
        hook.bidAndSwap(pool.key, params, type(uint256).max);
    }

    function test_scene4_bidInCurrency0() public {
        uint160 ref = toSqrtPriceX96(pool, REF_PRICE);
        uint256 estimate1 = hook.estimateArbProfit(pool.key, ref);
        hook.setBidCurrency(pool.key, true);
        uint256 estimate0 = hook.estimateArbProfit(pool.key, ref);
        assertApproxEqRel(estimate0, estimate1 * 1e18 / REF_PRICE, 0.001e18);

        _startAuction(pool, REF_PRICE);
        vm.roll(block.number + 6);
        _winAndCheck(pool, REF_PRICE);
    }

    // ------------------------------------------------------------------
    // Multi-pool: one hook, many pairs
    // ------------------------------------------------------------------

    function test_multiPool_independentAuctions() public {
        // pools[0] is the default 18/18 pool from setUp. Add four more with different shapes.
        PairConfig[4] memory cfgs = [
            // 18/6 decimals, price falls 4%
            PairConfig({decimals0: 18, decimals1: 6, price: 2500e18, liquidityValue1: 2_000_000, fee: 3000, tickSpacing: 60}),
            // 6/18 decimals, sub-1 price, rises 5%
            PairConfig({decimals0: 6, decimals1: 18, price: 0.0004e18, liquidityValue1: 100_000, fee: 3000, tickSpacing: 60}),
            // 8/18 decimals, large price, falls ~4.6%
            PairConfig({decimals0: 8, decimals1: 18, price: 65_000e18, liquidityValue1: 5_000_000, fee: 3000, tickSpacing: 60}),
            // 18/18, low fee tier, rises ~6.7%
            PairConfig({decimals0: 18, decimals1: 18, price: 1.5e18, liquidityValue1: 500_000, fee: 500, tickSpacing: 10})
        ];
        uint256[5] memory refs = [REF_PRICE, 2400e18, 0.00042e18, 62_000e18, 1.6e18];

        for (uint256 i; i < cfgs.length; i++) {
            _createPool(cfgs[i]);
        }
        assertEq(pools.length, 5);

        // Pool 4 pays its bid in currency0.
        hook.setBidCurrency(pools[4].key, true);

        // Market reopens: the keeper locks every pool.
        for (uint256 i; i < pools.length; i++) {
            assertGt(_startAuction(pools[i], refs[i]), 0);
            _assertAuction(pools[i]);
        }

        // Pool 2 clears early; the others stay locked.
        vm.roll(block.number + 6);
        _winAndCheck(pools[2], refs[2]);
        for (uint256 i; i < pools.length; i++) {
            if (i != 2) _assertAuction(pools[i]);
        }
        vm.expectRevert(_wrappedHookRevert(IHooks.beforeSwap.selector));
        _publicSwap(pools[0], true, 1e18);

        // Each remaining pool clears on its own.
        for (uint256 i; i < pools.length; i++) {
            if (i != 2) _winAndCheck(pools[i], refs[i]);
        }
        for (uint256 i; i < pools.length; i++) {
            _assertOpen(pools[i]);
        }
    }
}
