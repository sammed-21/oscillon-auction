// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AuctionScriptBase} from "./base/AuctionScriptBase.sol";
import {ReopenAuctionHook} from "../src/ReopenAuctionHook.sol";

/// @notice Keeper fallback: lock a pool at market reopen and start its Dutch auction.
/// @dev Env:
///        POOL         index in deployments/<chainId>.json (default 0)
///        PRICE_E6     reopen reference price, currency1 per currency0, scaled by 1e6 (e.g. 190.5 -> 190500000)
///        KEEPER_KEY   keeper private key (default PRIVATE_KEY)
contract StartAuctionScript is AuctionScriptBase {
    using PoolIdLibrary for *;

    function run() external {
        string memory json = loadDeployment();
        ReopenAuctionHook hook = loadHook(json);
        DeployedPool memory p = loadPool(json, vm.envOr("POOL", uint256(0)));
        uint160 ref = sqrtPriceFromE6(vm.envUint("PRICE_E6"), p.decimals0, p.decimals1);

        uint256 estimate = hook.estimateArbProfit(p.key, ref);

        vm.startBroadcast(keyOr("KEEPER_KEY"));
        uint256 startBid = hook.startAuction(p.key, ref);
        vm.stopBroadcast();

        console2.log("pool:", p.label);
        console2.log("refSqrtPriceX96:", uint256(ref));
        console2.log("arb estimate (raw bid currency):", estimate);
        console2.log("start bid (raw bid currency):", startBid);
        console2.log("auction blocks:", uint256(hook.auctionBlocks()));
    }
}
