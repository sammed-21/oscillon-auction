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

/// @notice Generic setup for the auction hook: one hook, any number of pools, any token pair.
/// @dev Uniswap conventions throughout:
///      - currency0 < currency1 by address.
///      - Prices are currency1 per currency0. `price` arguments are in whole tokens and scaled by
///        PRICE_PRECISION (1e18) so fractional prices work; decimals are applied when converting to raw units.
abstract contract AuctionFixture is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant PRICE_PRECISION = 1e18;

    uint64 constant AUCTION_BLOCKS = 10;
    uint32 constant PREMIUM_BPS = 15_000; // start at 1.5x the estimated arb profit
    uint24 constant DEFAULT_FEE = 3000;
    int24 constant DEFAULT_TICK_SPACING = 60;

    /// @notice One token pair and the pool behind the hook.
    struct PairConfig {
        uint8 decimals0; // decimals of the token that becomes currency0
        uint8 decimals1; // decimals of the token that becomes currency1
        uint256 price; // currency1 per currency0, whole tokens, 1e18-scaled
        uint256 liquidityValue1; // full-range position size, in whole currency1 tokens on each side
        uint24 fee;
        int24 tickSpacing;
    }

    struct PoolInfo {
        PoolKey key;
        PoolId id;
        uint8 decimals0;
        uint8 decimals1;
        uint256 lpTokenId;
    }

    address keeper = makeAddr("keeper");
    address bidder = makeAddr("bidder");
    address trader = makeAddr("trader");

    ReopenAuctionHook hook;
    PoolInfo[] pools;

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------

    function _deployHook() internal {
        deployArtifactsAndLabel();
        address flags =
            address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144));
        deployCodeTo(
            "ReopenAuctionHook.sol:ReopenAuctionHook",
            abi.encode(poolManager, address(this), keeper, AUCTION_BLOCKS, PREMIUM_BPS),
            flags
        );
        hook = ReopenAuctionHook(flags);
    }

    function defaultPair(uint256 price) internal pure returns (PairConfig memory) {
        return PairConfig({
            decimals0: 18,
            decimals1: 18,
            price: price,
            liquidityValue1: 1_000_000,
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING
        });
    }

    /// @notice Deploy a fresh token pair, create its pool on the hook and add full-range liquidity.
    function _createPool(PairConfig memory cfg) internal returns (PoolInfo memory p) {
        (Currency currency0, Currency currency1) = _deployPair(cfg.decimals0, cfg.decimals1);

        p.key = PoolKey(currency0, currency1, cfg.fee, cfg.tickSpacing, IHooks(hook));
        p.id = p.key.toId();
        p.decimals0 = cfg.decimals0;
        p.decimals1 = cfg.decimals1;

        uint160 sqrtPrice = toSqrtPriceX96(cfg.price, cfg.decimals0, cfg.decimals1);
        poolManager.initialize(p.key, sqrtPrice);

        // Size the position so each side holds ~liquidityValue1 / 2 worth of currency1.
        // Full range: amount1 = L * sqrtP  =>  L = amount1 / sqrtP.
        uint256 amount1 = cfg.liquidityValue1 * 10 ** cfg.decimals1 / 2;
        uint128 liquidity = uint128(Math.mulDiv(amount1, 1 << 96, sqrtPrice));

        int24 lower = TickMath.minUsableTick(cfg.tickSpacing);
        int24 upper = TickMath.maxUsableTick(cfg.tickSpacing);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPrice, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity
        );
        (p.lpTokenId,) = positionManager.mint(
            p.key, lower, upper, liquidity, a0 + 1, a1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );

        pools.push(p);
    }

    /// @dev Deploys two mock tokens so that the lower address (currency0) gets `decimals0`.
    ///      The next two CREATE addresses are known in advance, so deploy order decides who gets which decimals.
    function _deployPair(uint8 decimals0, uint8 decimals1) internal returns (Currency currency0, Currency currency1) {
        uint64 nonce = vm.getNonce(address(this));
        bool firstIsLower = vm.computeCreateAddress(address(this), nonce)
            < vm.computeCreateAddress(address(this), nonce + 1);
        MockERC20 first = new MockERC20("Token", "TKN", firstIsLower ? decimals0 : decimals1);
        MockERC20 second = new MockERC20("Token", "TKN", firstIsLower ? decimals1 : decimals0);
        (MockERC20 a, MockERC20 b) = firstIsLower ? (first, second) : (second, first);

        currency0 = Currency.wrap(address(a));
        currency1 = Currency.wrap(address(b));

        uint256 n = pools.length;
        vm.label(address(a), string.concat("Pool", vm.toString(n), ".currency0"));
        vm.label(address(b), string.concat("Pool", vm.toString(n), ".currency1"));

        _fundAndApprove(a, address(this));
        _fundAndApprove(b, address(this));
        _fundAndApprove(a, bidder);
        _fundAndApprove(b, bidder);
        _fundAndApprove(a, trader);
        _fundAndApprove(b, trader);
    }

    function _fundAndApprove(MockERC20 token, address who) internal {
        token.mint(who, 10 ** (token.decimals() + 12));
        vm.startPrank(who);
        token.approve(address(hook), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Price helpers
    // ------------------------------------------------------------------

    /// @notice sqrtPriceX96 for `price` (currency1 per currency0, whole tokens, 1e18-scaled).
    /// @dev raw price = price * 10^d1 / 10^d0; sqrtPriceX96 = sqrt(raw * 2^192).
    function toSqrtPriceX96(uint256 price, uint8 decimals0, uint8 decimals1) internal pure returns (uint160) {
        uint256 rawX192 = Math.mulDiv(price * 10 ** decimals1, 1 << 192, PRICE_PRECISION * 10 ** decimals0);
        return uint160(Math.sqrt(rawX192));
    }

    function toSqrtPriceX96(PoolInfo memory p, uint256 price) internal pure returns (uint160) {
        return toSqrtPriceX96(price, p.decimals0, p.decimals1);
    }

    /// @notice Value of (delta0, delta1) in raw currency1 units, marking currency0 at `sqrtPriceX96`.
    function valueIn1(int256 delta0, int256 delta1, uint160 sqrtPriceX96) internal pure returns (int256) {
        uint256 abs0 = delta0 < 0 ? uint256(-delta0) : uint256(delta0);
        uint256 v0 = Math.mulDiv(Math.mulDiv(abs0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        return delta1 + (delta0 < 0 ? -int256(v0) : int256(v0));
    }

    // ------------------------------------------------------------------
    // Swap helpers
    // ------------------------------------------------------------------

    /// @notice Swap params that push the pool exactly to `targetSqrtPrice` (exact-input, capped by the price limit).
    function arbParams(PoolInfo memory p, uint160 targetSqrtPrice) internal view returns (SwapParams memory) {
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(p.id);
        return SwapParams({
            zeroForOne: targetSqrtPrice < sqrtPrice, // price falls -> sell currency0
            amountSpecified: type(int128).min + 1, // effectively unlimited exact-in; the price limit stops it
            sqrtPriceLimitX96: targetSqrtPrice
        });
    }

    function sqrtPriceOf(PoolInfo memory p) internal view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = poolManager.getSlot0(p.id);
    }
}
