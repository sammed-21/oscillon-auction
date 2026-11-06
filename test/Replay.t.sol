// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {AuctionFixture} from "./utils/AuctionFixture.sol";

/// @notice Scene 5: replay market-reopen gaps through a vanilla pool and an auction pool side by side.
/// @dev For every pair in replay/gaps.json, two identical pools are created on the same tokens:
///        - vanilla: no hook. At reopen the first arbitrageur swaps to the open price and keeps the gap.
///        - auction: ReopenAuctionHook. The keeper starts the auction; a rational bidder waits until the
///          Dutch price drops below its real (fee-inclusive) profit, then wins and swaps. The bid goes to LPs.
///      Per event we record, in the pair's stable ("numeraire") currency, marked at the open price:
///        arb profit, LP take (swap fees + donated bid) and the winning bid.
///      Output: console table + replay/results.csv (for the frontend comparison chart).
contract ReplayTest is AuctionFixture {
    using stdJson for string;
    using EasyPosm for IPositionManager;

    string constant GAPS_PATH = "replay/gaps.json";
    string constant RESULTS_PATH = "replay/results.csv";
    uint256 constant NO_BID = type(uint256).max;

    struct PairRun {
        string label;
        PoolInfo vanilla;
        PoolInfo auction;
        bool bidIn0;
        uint8 numeraireDecimals;
    }

    struct EventResult {
        uint256 closeE6;
        uint256 openE6;
        int256 gapBps;
        int256 vanillaArb; // arbitrageur's profit in the vanilla pool
        int256 vanillaLp; // LP take in the vanilla pool (swap fees)
        uint256 bid; // winning bid in the auction pool
        int256 auctionArb; // auction winner's profit after paying the bid
        int256 auctionLp; // LP take in the auction pool (swap fees + bid)
        uint256 bidBlock; // blocks after auction start; NO_BID if nobody bid
    }

    /// @dev Running totals, normalized to 1e18 so pairs with different stable decimals add up.
    struct Totals {
        int256 vanillaArb;
        int256 vanillaLp;
        int256 bids;
        int256 auctionArb;
        int256 auctionLp;
        uint256 events;
        uint256 arbEvents;
    }

    function test_replay() public {
        _deployHook();
        string memory json = vm.readFile(GAPS_PATH);

        string memory csv =
            "pair,event,close,open,gapBps,vanillaArbProfit,vanillaLpTake,auctionBid,auctionWinnerProfit,auctionLpTake,bidBlock\n";
        Totals memory t;

        for (uint256 i; json.keyExists(string.concat(".pairs[", vm.toString(i), "]")); i++) {
            csv = string.concat(csv, _replayPair(json, i, t));
        }

        vm.writeFile(RESULTS_PATH, csv);
        _printTotals(t);

        // The auction never leaves LPs worse off than vanilla, and returns value when arbs are profitable.
        assertGe(t.auctionLp, t.vanillaLp, "auction LP take >= vanilla");
        if (t.arbEvents > 0) assertGt(t.bids, 0, "bids paid to LPs");
    }

    // ------------------------------------------------------------------
    // Per pair
    // ------------------------------------------------------------------

    function _replayPair(string memory json, uint256 i, Totals memory t) internal returns (string memory csv) {
        string memory k = string.concat(".pairs[", vm.toString(i), "]");
        PairConfig memory cfg = PairConfig({
            decimals0: uint8(json.readUint(string.concat(k, ".decimals0"))),
            decimals1: uint8(json.readUint(string.concat(k, ".decimals1"))),
            price: json.readUintArray(string.concat(k, ".closesE6"))[0] * 1e12,
            liquidityValue1: json.readUint(string.concat(k, ".liquidityValue1")),
            fee: uint24(json.readUint(string.concat(k, ".fee"))),
            tickSpacing: int24(int256(json.readUint(string.concat(k, ".tickSpacing"))))
        });
        uint256[] memory closes = json.readUintArray(string.concat(k, ".closesE6"));
        uint256[] memory opens = json.readUintArray(string.concat(k, ".opensE6"));
        require(closes.length == opens.length, "closes/opens length mismatch");

        PairRun memory r;
        r.label = json.readString(string.concat(k, ".label"));
        r.bidIn0 = json.readBool(string.concat(k, ".bidInCurrency0"));
        r.numeraireDecimals = r.bidIn0 ? cfg.decimals0 : cfg.decimals1;

        (Currency c0, Currency c1) = _deployPair(cfg.decimals0, cfg.decimals1);
        r.vanilla = _createPool(cfg, c0, c1, IHooks(address(0)));
        r.auction = _createPool(cfg, c0, c1, IHooks(hook));
        if (r.bidIn0) hook.setBidCurrency(r.auction.key, true);

        console2.log("");
        console2.log("==== %s ====", r.label);

        Totals memory pt;
        for (uint256 e; e < closes.length; e++) {
            EventResult memory res = _replayEvent(r, closes[e], opens[e]);
            _accumulate(pt, res, r.numeraireDecimals);
            _logEvent(r, e, res);
            csv = string.concat(csv, _csvRow(r, e, res));
        }
        _printPairSummary(pt);
        _add(t, pt);
    }

    // ------------------------------------------------------------------
    // Per event
    // ------------------------------------------------------------------

    function _replayEvent(PairRun memory r, uint256 closeE6, uint256 openE6)
        internal
        returns (EventResult memory res)
    {
        res.closeE6 = closeE6;
        res.openE6 = openE6;
        res.gapBps = (int256(openE6) - int256(closeE6)) * 10_000 / int256(closeE6);

        uint160 closeSqrt = toSqrtPriceX96(r.vanilla, closeE6 * 1e12);
        uint160 openSqrt = toSqrtPriceX96(r.vanilla, openE6 * 1e12);

        // Market close: both pools sit at the close price; clear fees from the alignment swap.
        _align(r.vanilla, closeSqrt);
        _align(r.auction, closeSqrt);
        _lpTake(r, r.vanilla, closeSqrt);
        _lpTake(r, r.auction, closeSqrt);

        // Reopen, vanilla pool: the first arbitrageur takes the gap.
        res.vanillaArb = _vanillaArb(r, openSqrt);
        res.vanillaLp = _lpTake(r, r.vanilla, openSqrt);

        // Reopen, auction pool.
        _auction(r, openSqrt, res);
        res.auctionLp = _lpTake(r, r.auction, openSqrt);
    }

    /// @dev Arb swaps to the open price only if it is profitable after fees; otherwise nobody trades.
    function _vanillaArb(PairRun memory r, uint160 openSqrt) internal returns (int256 profit) {
        uint256 snap = vm.snapshotState();
        SwapParams memory params = arbParams(r.vanilla, openSqrt);
        vm.prank(bidder);
        BalanceDelta d = swapTest.swap(r.vanilla.key, params, PoolSwapTest.TestSettings(false, false), "");
        profit = _value(r, d.amount0(), d.amount1(), openSqrt);
        if (profit <= 0) {
            vm.revertToStateAndDelete(snap);
            return 0;
        }
        vm.deleteStateSnapshot(snap);
    }

    /// @dev Keeper starts the auction. The bidder knows its fee-inclusive profit P (simulated as a zero-price
    ///      win) and bids in the first block where the Dutch price is below P. If P <= 0 nobody bids.
    function _auction(PairRun memory r, uint160 openSqrt, EventResult memory res) internal {
        vm.prank(keeper);
        hook.startAuction(r.auction.key, openSqrt);
        uint256 start = block.number;

        uint256 snap = vm.snapshotState();
        vm.roll(start + AUCTION_BLOCKS);
        (int256 maxProfit,) = _bidAndValue(r, openSqrt);
        vm.revertToStateAndDelete(snap);
        vm.roll(start);

        if (maxProfit <= 0) {
            vm.roll(start + AUCTION_BLOCKS + 1); // auction expires, pool reopens untouched
            res.bidBlock = NO_BID;
            return;
        }

        while (hook.currentPrice(r.auction.id) >= uint256(maxProfit)) {
            vm.roll(block.number + 1);
        }
        res.bidBlock = block.number - start;
        (res.auctionArb, res.bid) = _bidAndValue(r, openSqrt);
        vm.roll(block.number + 1);
    }

    /// @return profit bidder's net value change (swap + bid) marked at the open price
    function _bidAndValue(PairRun memory r, uint160 openSqrt) internal returns (int256 profit, uint256 bid) {
        PoolInfo memory p = r.auction;
        uint256 b0 = p.key.currency0.balanceOf(bidder);
        uint256 b1 = p.key.currency1.balanceOf(bidder);
        SwapParams memory params = arbParams(p, openSqrt);
        vm.prank(bidder);
        (, bid) = hook.bidAndSwap(p.key, params, type(uint256).max);
        int256 d0 = int256(p.key.currency0.balanceOf(bidder)) - int256(b0);
        int256 d1 = int256(p.key.currency1.balanceOf(bidder)) - int256(b1);
        profit = _value(r, d0, d1, openSqrt);
    }

    function _align(PoolInfo memory p, uint160 targetSqrt) internal {
        if (sqrtPriceOf(p) == targetSqrt) return;
        SwapParams memory params = arbParams(p, targetSqrt);
        vm.prank(trader);
        swapTest.swap(p.key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    /// @dev Collect the LP position's fees (incl. donations) and value them in the numeraire.
    function _lpTake(PairRun memory r, PoolInfo memory p, uint160 sqrtP) internal returns (int256) {
        BalanceDelta fees = positionManager.collect(p.lpTokenId, 0, 0, address(this), block.timestamp, "");
        return _value(r, fees.amount0(), fees.amount1(), sqrtP);
    }

    /// @dev Value (d0, d1) in the pair's numeraire (raw units), marking the other currency at sqrtP.
    function _value(PairRun memory r, int256 d0, int256 d1, uint160 sqrtP) internal pure returns (int256) {
        int256 v1 = valueIn1(d0, d1, sqrtP);
        if (!r.bidIn0) return v1;
        // v0 = v1 / price = v1 * 2^192 / sqrtP^2
        uint256 abs1 = v1 < 0 ? uint256(-v1) : uint256(v1);
        uint256 v0 = Math.mulDiv(Math.mulDiv(abs1, 1 << 96, sqrtP), 1 << 96, sqrtP);
        return v1 < 0 ? -int256(v0) : int256(v0);
    }

    // ------------------------------------------------------------------
    // Aggregation and output
    // ------------------------------------------------------------------

    function _norm(int256 v, uint8 decimals) internal pure returns (int256) {
        return v * int256(10 ** (18 - decimals));
    }

    function _accumulate(Totals memory t, EventResult memory res, uint8 dec) internal pure {
        t.vanillaArb += _norm(res.vanillaArb, dec);
        t.vanillaLp += _norm(res.vanillaLp, dec);
        t.bids += _norm(int256(res.bid), dec);
        t.auctionArb += _norm(res.auctionArb, dec);
        t.auctionLp += _norm(res.auctionLp, dec);
        t.events++;
        if (res.vanillaArb > 0) t.arbEvents++;
    }

    function _add(Totals memory t, Totals memory p) internal pure {
        t.vanillaArb += p.vanillaArb;
        t.vanillaLp += p.vanillaLp;
        t.bids += p.bids;
        t.auctionArb += p.auctionArb;
        t.auctionLp += p.auctionLp;
        t.events += p.events;
        t.arbEvents += p.arbEvents;
    }

    function _logEvent(PairRun memory r, uint256 e, EventResult memory res) internal pure {
        uint8 d = r.numeraireDecimals;
        console2.log(
            string.concat(
                "#",
                vm.toString(e),
                " ",
                _fmt(int256(res.closeE6), 6, 4),
                " -> ",
                _fmt(int256(res.openE6), 6, 4),
                " (",
                _fmtBps(res.gapBps),
                ")"
            )
        );
        console2.log(
            string.concat(
                "   vanilla: arb keeps ", _fmt(res.vanillaArb, d, 2), " | LPs get ", _fmt(res.vanillaLp, d, 2)
            )
        );
        console2.log(
            string.concat(
                "   auction: bid ",
                _fmt(int256(res.bid), d, 2),
                res.bidBlock == NO_BID ? " (no bid)" : string.concat(" @blk ", vm.toString(res.bidBlock)),
                " | winner keeps ",
                _fmt(res.auctionArb, d, 2),
                " | LPs get ",
                _fmt(res.auctionLp, d, 2)
            )
        );
    }

    function _csvRow(PairRun memory r, uint256 e, EventResult memory res) internal pure returns (string memory) {
        uint8 d = r.numeraireDecimals;
        return string.concat(
            string.concat(r.label, ",", vm.toString(e), ","),
            string.concat(_fmt(int256(res.closeE6), 6, 6), ",", _fmt(int256(res.openE6), 6, 6), ","),
            string.concat(vm.toString(res.gapBps), ","),
            string.concat(_fmt(res.vanillaArb, d, 6), ",", _fmt(res.vanillaLp, d, 6), ","),
            string.concat(_fmt(int256(res.bid), d, 6), ",", _fmt(res.auctionArb, d, 6), ","),
            string.concat(_fmt(res.auctionLp, d, 6), ",", res.bidBlock == NO_BID ? "" : vm.toString(res.bidBlock), "\n")
        );
    }

    function _printPairSummary(Totals memory t) internal pure {
        console2.log(
            string.concat(
                "   -- pair total: vanilla arb ",
                _fmt(t.vanillaArb, 18, 2),
                " | bids to LPs ",
                _fmt(t.bids, 18, 2),
                " | recaptured ",
                _pct(t.bids, t.vanillaArb)
            )
        );
    }

    function _printTotals(Totals memory t) internal pure {
        console2.log("");
        console2.log("================ REPLAY SUMMARY (all pairs, in stable units) ================");
        console2.log(string.concat("events: ", vm.toString(t.events), " | profitable gaps: ", vm.toString(t.arbEvents)));
        console2.log(
            string.concat(
                "VANILLA  arbs extract ", _fmt(t.vanillaArb, 18, 2), " | LPs get ", _fmt(t.vanillaLp, 18, 2)
            )
        );
        console2.log(
            string.concat(
                "AUCTION  winners keep ",
                _fmt(t.auctionArb, 18, 2),
                " | LPs get ",
                _fmt(t.auctionLp, 18, 2),
                " (bids ",
                _fmt(t.bids, 18, 2),
                ")"
            )
        );
        console2.log(string.concat("RECAPTURED for LPs: ", _pct(t.bids, t.vanillaArb), " of reopen arbitrage"));
        console2.log(string.concat("results written to ", RESULTS_PATH));
    }

    // ------------------------------------------------------------------
    // Formatting
    // ------------------------------------------------------------------

    /// @dev Fixed-point to decimal string with `frac` digits (truncated).
    function _fmt(int256 v, uint8 decimals, uint8 frac) internal pure returns (string memory) {
        bool neg = v < 0;
        uint256 a = neg ? uint256(-v) : uint256(v);
        uint256 unit = 10 ** decimals;
        uint256 fracVal = (a % unit) * 10 ** frac / unit;
        string memory f = vm.toString(fracVal);
        while (bytes(f).length < frac) f = string.concat("0", f);
        return string.concat(neg ? "-" : "", vm.toString(a / unit), frac > 0 ? "." : "", f);
    }

    function _fmtBps(int256 bps) internal pure returns (string memory) {
        return string.concat(bps >= 0 ? "+" : "", _fmt(bps, 2, 2), "%");
    }

    function _pct(int256 num, int256 den) internal pure returns (string memory) {
        if (den <= 0) return "n/a";
        return string.concat(_fmt(num * 10_000 / den, 2, 2), "%");
    }
}
