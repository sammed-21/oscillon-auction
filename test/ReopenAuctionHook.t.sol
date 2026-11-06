// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
contract ReopenAuctionHookTest is AuctionFixture {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    uint256 constant CLOSE_PRICE = 180; // NVDA Friday close
    uint256 constant REOPEN_PRICE = 190; // NVDA Monday open

    function setUp() public {
        _setUpPool(CLOSE_PRICE);
    }

    function _wrappedHookRevert(bytes4 hookSelector) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            abi.encodeWithSelector(ReopenAuctionHook.AuctionActive.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _publicSwap(address who, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: who,
            deadline: block.timestamp + 1
        });
    }

    /// @dev External so `expectRevert` covers the whole mint (EasyPosm makes calls before the revert).
    function addFullRangeLiquidity(uint128 liquidity) external {
        positionManager.mint(
            poolKey,
            TickMath.minUsableTick(TICK_SPACING),
            TickMath.maxUsableTick(TICK_SPACING),
            liquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function _startAuction() internal returns (uint256 startBid) {
        vm.prank(keeper);
        startBid = hook.startAuction(poolKey, toSqrtPriceX96(REOPEN_PRICE));
    }

    // ------------------------------------------------------------------
    // Scene 1: market open
    // ------------------------------------------------------------------

    function test_scene1_openMarketSwapsNormally() public {
        assertEq(uint8(hook.phase(poolId)), uint8(ReopenAuctionHook.Phase.OPEN));
        BalanceDelta d = _publicSwap(trader, true, 1e18);
        assertEq(d.amount0(), -1e18);
        assertGt(d.amount1(), 0);
    }

    // ------------------------------------------------------------------
    // Scene 2: reopen locks the pool
    // ------------------------------------------------------------------

    function test_scene2_startAuctionLocksPool() public {
        uint256 startBid = _startAuction();

        // L * (b - a)^2 / a with L = 10_000, sqrt(180) -> sqrt(190): ~101 USDG, times 1.5 premium.
        assertApproxEqRel(startBid, 151.4e18, 0.01e18);
        assertEq(uint8(hook.phase(poolId)), uint8(ReopenAuctionHook.Phase.AUCTION));

        // Public swaps revert.
        vm.expectRevert(_wrappedHookRevert(IHooks.beforeSwap.selector));
        _publicSwap(trader, false, 1000e18);

        // JIT liquidity is blocked.
        vm.expectRevert(_wrappedHookRevert(IHooks.beforeAddLiquidity.selector));
        this.addFullRangeLiquidity(1e18);

        // Cannot start a second auction on top.
        vm.prank(keeper);
        vm.expectRevert(ReopenAuctionHook.AuctionActive.selector);
        hook.startAuction(poolKey, toSqrtPriceX96(REOPEN_PRICE));
    }

    function test_scene2_priceFallsBlockByBlock() public {
        uint256 startBid = _startAuction();
        uint256 last = hook.currentPrice(poolId);
        assertEq(last, startBid);
        for (uint256 i = 1; i <= AUCTION_BLOCKS; i++) {
            vm.roll(block.number + 1);
            uint256 p = hook.currentPrice(poolId);
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
        _startAuction();
        // At 1.5x the fee-free estimate, the first blocks are unprofitable once the 0.3% swap fee is paid.
        // A rational bidder waits until the price drops below its real profit: block 5 = 50% of start.
        vm.roll(block.number + 5);

        uint256 price = hook.currentPrice(poolId);
        uint160 ref = toSqrtPriceX96(REOPEN_PRICE);

        uint256 nvdaBefore = _bal(xNVDA, bidder);
        uint256 usdgBefore = _bal(usdg, bidder);

        SwapParams memory params = arbParams(ref);
        vm.prank(bidder);
        (BalanceDelta swapDelta, uint256 bid) = hook.bidAndSwap(poolKey, params, price);

        assertEq(bid, price);
        assertGt(bid, 0);

        // Pool moved to the reference price.
        (uint160 sqrtAfter,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtAfter, ref);

        // Bidder bought xNVDA with USDG and paid swap input + bid.
        int256 dNvda = int256(_bal(xNVDA, bidder)) - int256(nvdaBefore);
        int256 dUsdg = int256(_bal(usdg, bidder)) - int256(usdgBefore);
        assertEq(dNvda, int256(swapDelta.amount0()));
        assertEq(dUsdg, int256(swapDelta.amount1()) - int256(bid));

        // Bidder still profits when xNVDA is marked at the reopen price.
        assertGt(_pnlAtRef(dNvda, dUsdg, REOPEN_PRICE), 0);

        // LPs collect the bid plus the normal swap fee.
        uint256 swapFee = uint256(-int256(swapDelta.amount1())) * FEE / 1e6;
        BalanceDelta fees = positionManager.collect(lpTokenId, 0, 0, address(this), block.timestamp, "");
        assertApproxEqAbs(uint256(int256(fees.amount1())), bid + swapFee, 1e6);

        // Pool is open again.
        assertEq(uint8(hook.phase(poolId)), uint8(ReopenAuctionHook.Phase.OPEN));
        _publicSwap(trader, true, 1e18);
    }

    function test_scene3_priceDownGap() public {
        // Reopen below the close: winner sells xNVDA.
        vm.prank(keeper);
        uint160 ref = toSqrtPriceX96(170);
        uint256 startBid = hook.startAuction(poolKey, ref);
        assertGt(startBid, 0);

        SwapParams memory params = arbParams(ref);
        vm.prank(bidder);
        (BalanceDelta d, uint256 bid) = hook.bidAndSwap(poolKey, params, type(uint256).max);
        assertEq(bid, startBid);
        assertLt(d.amount0(), 0);
        (uint160 sqrtAfter,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtAfter, ref);
    }

    // ------------------------------------------------------------------
    // Scene 4: edge cases
    // ------------------------------------------------------------------

    function test_scene4_noBidPoolReopensAfterExpiry() public {
        _startAuction();
        vm.roll(block.number + AUCTION_BLOCKS + 1);
        assertEq(uint8(hook.phase(poolId)), uint8(ReopenAuctionHook.Phase.OPEN));
        assertEq(hook.currentPrice(poolId), 0);
        _publicSwap(trader, false, 1000e18);

        SwapParams memory params = arbParams(toSqrtPriceX96(REOPEN_PRICE));
        vm.prank(bidder);
        vm.expectRevert(ReopenAuctionHook.NoActiveAuction.selector);
        hook.bidAndSwap(poolKey, params, type(uint256).max);
    }

    function test_scene4_maxBidGuard() public {
        uint256 startBid = _startAuction();
        SwapParams memory params = arbParams(toSqrtPriceX96(REOPEN_PRICE));
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(ReopenAuctionHook.BidTooHigh.selector, startBid, startBid - 1));
        hook.bidAndSwap(poolKey, params, startBid - 1);
    }

    function test_scene4_onlyKeeperStarts() public {
        uint160 ref = toSqrtPriceX96(REOPEN_PRICE);
        vm.prank(trader);
        vm.expectRevert(ReopenAuctionHook.NotKeeper.selector);
        hook.startAuction(poolKey, ref);
    }

    function test_scene4_ownerCancelReopens() public {
        _startAuction();
        hook.cancelAuction(poolKey);
        assertEq(uint8(hook.phase(poolId)), uint8(ReopenAuctionHook.Phase.OPEN));
        _publicSwap(trader, true, 1e18);
    }

    function test_scene4_secondBidderLoses() public {
        _startAuction();
        SwapParams memory params = arbParams(toSqrtPriceX96(REOPEN_PRICE));
        vm.prank(bidder);
        hook.bidAndSwap(poolKey, params, type(uint256).max);

        vm.prank(trader);
        vm.expectRevert(ReopenAuctionHook.NoActiveAuction.selector);
        hook.bidAndSwap(poolKey, params, type(uint256).max);
    }

    function test_scene4_quoteInCurrency0() public {
        hook.setQuoteCurrency(poolKey, true);
        uint160 ref = toSqrtPriceX96(REOPEN_PRICE);
        uint256 profit1 = 101e18; // ~USDG profit, see scene 2
        uint256 est0 = hook.estimateArbProfit(poolKey, ref);
        assertApproxEqRel(est0, profit1 / REOPEN_PRICE, 0.01e18);

        vm.prank(keeper);
        hook.startAuction(poolKey, ref);
        SwapParams memory params = arbParams(ref);
        vm.prank(bidder);
        (, uint256 bid) = hook.bidAndSwap(poolKey, params, type(uint256).max);
        BalanceDelta fees = positionManager.collect(lpTokenId, 0, 0, address(this), block.timestamp, "");
        assertGe(uint256(int256(fees.amount0())), bid - 1);
    }
}
