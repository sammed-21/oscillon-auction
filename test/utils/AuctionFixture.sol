// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./libraries/EasyPosm.sol";
import {BaseTest} from "./BaseTest.sol";
import {ReopenAuctionHook} from "../../src/ReopenAuctionHook.sol";

/// @notice Shared setup: an xNVDA (currency0) / USDG (currency1) pool behind the auction hook.
///         Prices are "USDG per xNVDA"; both tokens use 18 decimals.
abstract contract AuctionFixture is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint64 constant AUCTION_BLOCKS = 10;
    uint32 constant PREMIUM_BPS = 15_000; // start at 1.5x the estimated arb profit
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint128 constant LIQUIDITY = 10_000e18;

    address keeper = makeAddr("keeper");
    address bidder = makeAddr("bidder");
    address trader = makeAddr("trader");

    Currency xNVDA; // currency0
    Currency usdg; // currency1

    ReopenAuctionHook hook;
    PoolKey poolKey;
    PoolId poolId;
    uint256 lpTokenId;

    function _setUpPool(uint256 closePrice) internal {
        deployArtifactsAndLabel();
        (xNVDA, usdg) = deployCurrencyPair();
        vm.label(Currency.unwrap(xNVDA), "xNVDA");
        vm.label(Currency.unwrap(usdg), "USDG");

        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "ReopenAuctionHook.sol:ReopenAuctionHook",
            abi.encode(poolManager, address(this), keeper, AUCTION_BLOCKS, PREMIUM_BPS),
            flags
        );
        hook = ReopenAuctionHook(flags);

        poolKey = PoolKey(xNVDA, usdg, FEE, TICK_SPACING, IHooks(hook));
        poolId = poolKey.toId();
        uint160 sqrtPrice = toSqrtPriceX96(closePrice);
        poolManager.initialize(poolKey, sqrtPrice);

        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPrice, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), LIQUIDITY
        );
        (lpTokenId,) = positionManager.mint(
            poolKey, lower, upper, LIQUIDITY, a0 + 1, a1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        _fund(bidder);
        _fund(trader);
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(xNVDA)).mint(who, 1_000_000e18);
        MockERC20(Currency.unwrap(usdg)).mint(who, 100_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(xNVDA)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(usdg)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(xNVDA)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(usdg)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev price = USDG per xNVDA (whole units). sqrtPriceX96 = sqrt(price * 2^192).
    function toSqrtPriceX96(uint256 price) internal pure returns (uint160) {
        return uint160(Math.sqrt(price << 192));
    }

    /// @dev Inverse of toSqrtPriceX96, scaled by 1e18.
    function poolPriceE18() internal view returns (uint256) {
        (uint160 s,,,) = poolManager.getSlot0(poolId);
        return Math.mulDiv(uint256(s) * uint256(s), 1e18, 1 << 192);
    }

    /// @dev Swap params that push the pool exactly to `targetSqrtPrice` (exact-input, capped by price limit).
    function arbParams(uint160 targetSqrtPrice) internal view returns (SwapParams memory) {
        (uint160 s,,,) = poolManager.getSlot0(poolId);
        bool zeroForOne = targetSqrtPrice < s; // price falls -> sell xNVDA
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(1_000_000e18), // huge exact-in; the price limit stops it
            sqrtPriceLimitX96: targetSqrtPrice
        });
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.balanceOf(who);
    }

    /// @dev Bidder P&L in USDG (1e18), marking xNVDA at `refPrice`.
    function _pnlAtRef(int256 dNvda, int256 dUsdg, uint256 refPrice) internal pure returns (int256) {
        return dUsdg + dNvda * int256(refPrice);
    }
}
