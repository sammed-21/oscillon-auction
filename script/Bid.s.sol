// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {AuctionScriptBase} from "./base/AuctionScriptBase.sol";
import {ReopenAuctionHook} from "../src/ReopenAuctionHook.sol";

/// @notice Bidder: pay the current Dutch price, arb the pool to the reference price, LPs get the bid.
/// @dev Env:
///        POOL         index in deployments/<chainId>.json (default 0)
///        MAX_BID      max raw bid you accept (default: current price, i.e. "take it now")
///        BIDDER_KEY   bidder private key (default PRIVATE_KEY)
///        MINT_MOCKS   mint mock tokens to the bidder if needed (default true; mocks only)
///      The swap target is the auction's own reference price, read from the hook.
contract BidScript is AuctionScriptBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        string memory json = loadDeployment();
        ReopenAuctionHook hook = loadHook(json);
        DeployedPool memory p = loadPool(json, vm.envOr("POOL", uint256(0)));
        PoolId id = p.key.toId();

        (,, uint160 ref,, bool active) = hook.auctions(id);
        require(active && hook.phase(id) == ReopenAuctionHook.Phase.AUCTION, "no live auction");

        uint256 price = hook.currentPrice(id);
        uint256 maxBid = vm.envOr("MAX_BID", price);
        (uint160 sqrtNow,,,) = hook.poolManager().getSlot0(id);
        SwapParams memory params = SwapParams({
            zeroForOne: ref < sqrtNow,
            amountSpecified: type(int128).min + 1, // exact-in, stopped by the price limit
            sqrtPriceLimitX96: ref
        });

        uint256 pk = keyOr("BIDDER_KEY");
        address bidder = vm.addr(pk);

        vm.startBroadcast(pk);
        if (vm.envOr("MINT_MOCKS", true)) {
            _topUp(p.key.currency0, bidder);
            _topUp(p.key.currency1, bidder);
        }
        IERC20(Currency.unwrap(p.key.currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(p.key.currency1)).approve(address(hook), type(uint256).max);
        (BalanceDelta d, uint256 bid) = hook.bidAndSwap(p.key, params, maxBid);
        vm.stopBroadcast();

        console2.log("pool:", p.label);
        console2.log("bid at simulation block (raw):", bid);
        console2.log("note: the Dutch price is charged at the mined block; the AuctionWon event has the final bid");
        console2.log("swap amount0:", int256(d.amount0()));
        console2.log("swap amount1:", int256(d.amount1()));
    }

    function _topUp(Currency c, address who) internal {
        MockERC20 t = MockERC20(Currency.unwrap(c));
        uint256 want = 10 ** (uint256(t.decimals()) + 12);
        if (t.balanceOf(who) < want) t.mint(who, want);
    }
}
