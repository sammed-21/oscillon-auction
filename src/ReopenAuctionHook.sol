// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title ReopenAuctionHook
/// @notice Sells the first swap after a market reopen to the highest bidder and pays the bid to LPs.
///         One hook serves any number of pools; all state is keyed by PoolId.
/// @dev Flow (per pool):
///   1. The off-chain market for the pool's underlying reopens. The pool still sits at the stale close price.
///   2. The keeper calls `startAuction(key, refSqrtPriceX96)`. The pool locks: public swaps and
///      liquidity adds revert.
///   3. A Dutch auction runs for `auctionBlocks` blocks. The price starts at `startBid` (an on-chain
///      estimate of the arbitrage profit, scaled by `startPremiumBps`) and falls linearly to 0.
///   4. The first caller of `bidAndSwap` pays the current price and swaps in the same transaction.
///      The hook donates the bid to in-range LPs and reopens the pool.
///   5. If no one bids before `endBlock`, the pool reopens on its own.
///   Bids are paid in currency1 by default, or currency0 when `bidInCurrency0[poolId]` is set.
contract ReopenAuctionHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Phase {
        OPEN,
        AUCTION
    }

    struct Auction {
        uint64 startBlock;
        uint64 endBlock;
        uint160 refSqrtPriceX96;
        uint256 startBid;
        bool active;
    }

    struct CallbackData {
        address bidder;
        PoolKey key;
        SwapParams params;
        uint256 bid;
    }

    // ------------------------------------------------------------------
    // Errors and events
    // ------------------------------------------------------------------

    error NotOwner();
    error NotKeeper();
    error AuctionActive();
    error NoActiveAuction();
    error BidTooHigh(uint256 price, uint256 maxBid);
    error InvalidRefPrice();
    error NativeCurrencyUnsupported();

    event AuctionStarted(
        PoolId indexed poolId, uint160 refSqrtPriceX96, uint256 startBid, uint64 startBlock, uint64 endBlock
    );
    event AuctionWon(PoolId indexed poolId, address indexed winner, uint256 bid, Currency bidCurrency, BalanceDelta swapDelta);
    event AuctionCancelled(PoolId indexed poolId);
    event KeeperSet(address keeper);
    event ConfigSet(uint64 auctionBlocks, uint32 startPremiumBps);
    event BidCurrencySet(PoolId indexed poolId, bool bidInCurrency0);

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    address public owner;
    address public keeper;

    /// @notice Length of the Dutch auction, in blocks.
    uint64 public auctionBlocks;
    /// @notice Start price = estimated arb profit * startPremiumBps / 10_000.
    uint32 public startPremiumBps;

    mapping(PoolId => Auction) public auctions;
    mapping(PoolId => bool) public bidInCurrency0;

    constructor(IPoolManager _poolManager, address _owner, address _keeper, uint64 _auctionBlocks, uint32 _premiumBps)
        BaseHook(_poolManager)
    {
        owner = _owner;
        keeper = _keeper;
        auctionBlocks = _auctionBlocks;
        startPremiumBps = _premiumBps;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner) revert NotKeeper();
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
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

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setConfig(uint64 _auctionBlocks, uint32 _premiumBps) external onlyOwner {
        auctionBlocks = _auctionBlocks;
        startPremiumBps = _premiumBps;
        emit ConfigSet(_auctionBlocks, _premiumBps);
    }

    function setBidCurrency(PoolKey calldata key, bool _bidInCurrency0) external onlyOwner {
        bidInCurrency0[key.toId()] = _bidInCurrency0;
        emit BidCurrencySet(key.toId(), _bidInCurrency0);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @notice Emergency exit: unlock the pool without a winner.
    function cancelAuction(PoolKey calldata key) external onlyOwner {
        PoolId id = key.toId();
        if (!auctions[id].active) revert NoActiveAuction();
        auctions[id].active = false;
        emit AuctionCancelled(id);
    }

    // ------------------------------------------------------------------
    // Keeper: lock the pool at market reopen
    // ------------------------------------------------------------------

    /// @param refSqrtPriceX96 The reopen reference price (the underlying's first print), as a sqrtPriceX96
    ///        (currency1 per currency0, raw units, Q64.96).
    function startAuction(PoolKey calldata key, uint160 refSqrtPriceX96) external onlyKeeper returns (uint256 startBid) {
        if (refSqrtPriceX96 == 0) revert InvalidRefPrice();
        PoolId id = key.toId();
        if (_isLive(auctions[id])) revert AuctionActive();

        startBid = estimateArbProfit(key, refSqrtPriceX96) * startPremiumBps / 10_000;

        uint64 start = uint64(block.number);
        uint64 end = start + auctionBlocks;
        auctions[id] = Auction({
            startBlock: start,
            endBlock: end,
            refSqrtPriceX96: refSqrtPriceX96,
            startBid: startBid,
            active: true
        });

        emit AuctionStarted(id, refSqrtPriceX96, startBid, start, end);
    }

    // ------------------------------------------------------------------
    // Bidder: win the auction and take the first swap
    // ------------------------------------------------------------------

    /// @notice Pay the current Dutch price, swap, donate the payment to LPs, reopen the pool.
    /// @dev The bidder must approve this hook for the swap's input currency and the bid currency.
    ///      Use `params.sqrtPriceLimitX96` for slippage protection on the swap.
    /// @param maxBid Revert if the current price is above this.
    function bidAndSwap(PoolKey calldata key, SwapParams calldata params, uint256 maxBid)
        external
        returns (BalanceDelta swapDelta, uint256 bid)
    {
        if (key.currency0.isAddressZero()) revert NativeCurrencyUnsupported();
        PoolId id = key.toId();
        Auction storage a = auctions[id];
        if (!_isLive(a)) revert NoActiveAuction();

        bid = currentPrice(id);
        if (bid > maxBid) revert BidTooHigh(bid, maxBid);

        // Close the auction before any external call.
        a.active = false;

        swapDelta = abi.decode(
            poolManager.unlock(abi.encode(CallbackData({bidder: msg.sender, key: key, params: params, bid: bid}))),
            (BalanceDelta)
        );

        emit AuctionWon(id, msg.sender, bid, bidCurrency(key), swapDelta);
    }

    function unlockCallback(bytes calldata raw) external onlyPoolManager returns (bytes memory) {
        CallbackData memory d = abi.decode(raw, (CallbackData));

        // The hook is msg.sender here, so PoolManager skips this hook's own beforeSwap.
        BalanceDelta delta = poolManager.swap(d.key, d.params, "");

        // Pay the bid to LPs in range at the new (post-arb) price.
        if (d.bid > 0) {
            if (bidInCurrency0[d.key.toId()]) poolManager.donate(d.key, d.bid, 0, "");
            else poolManager.donate(d.key, 0, d.bid, "");
        }

        _settleWithBidder(d.key.currency0, d.bidder);
        _settleWithBidder(d.key.currency1, d.bidder);

        return abi.encode(delta);
    }

    function _settleWithBidder(Currency currency, address bidder) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) currency.settle(poolManager, bidder, uint256(-delta), false);
        else if (delta > 0) currency.take(poolManager, bidder, uint256(delta), false);
    }

    // ------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_isLive(auctions[key.toId()])) revert AuctionActive();
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Blocks just-in-time liquidity that would dilute the donation.
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (_isLive(auctions[key.toId()])) revert AuctionActive();
        return BaseHook.beforeAddLiquidity.selector;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function phase(PoolId id) external view returns (Phase) {
        return _isLive(auctions[id]) ? Phase.AUCTION : Phase.OPEN;
    }

    /// @notice Current Dutch price. Falls linearly from startBid at startBlock to 0 at endBlock.
    function currentPrice(PoolId id) public view returns (uint256) {
        Auction memory a = auctions[id];
        if (!_isLive(a)) return 0;
        uint256 duration = a.endBlock - a.startBlock;
        if (duration == 0) return 0;
        return a.startBid * (a.endBlock - block.number) / duration;
    }

    /// @notice Profit from moving the pool from its current price to `refSqrtPriceX96`, assuming the
    ///         current in-range liquidity holds across the move. Exact for full-range positions.
    /// @dev With liquidity L and sqrt prices a (pool) and b (ref), profit in currency1 = L * (b - a)^2 / a.
    ///      Converted to currency0 at the ref price when the pool bids in currency0.
    function estimateArbProfit(PoolKey calldata key, uint160 refSqrtPriceX96) public view returns (uint256 profit) {
        PoolId id = key.toId();
        (uint160 a,,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        uint256 b = refSqrtPriceX96;
        uint256 diff = b > a ? b - a : a - b;

        // profit1 = L * diff^2 / (a * 2^96)
        profit = FullMath.mulDiv(FullMath.mulDiv(liquidity, diff, a), diff, FixedPoint96.Q96);

        if (bidInCurrency0[id]) {
            // profit0 = profit1 / p_ref = profit1 * 2^192 / b^2
            profit = FullMath.mulDiv(FullMath.mulDiv(profit, FixedPoint96.Q96, b), FixedPoint96.Q96, b);
        }
    }

    function _isLive(Auction memory a) internal view returns (bool) {
        return a.active && block.number <= a.endBlock;
    }

    function bidCurrency(PoolKey calldata key) public view returns (Currency) {
        return bidInCurrency0[key.toId()] ? key.currency0 : key.currency1;
    }
}
