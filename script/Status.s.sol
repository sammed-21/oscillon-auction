// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {AuctionScriptBase} from "./base/AuctionScriptBase.sol";
import {ReopenAuctionHook} from "../src/ReopenAuctionHook.sol";

/// @notice Read-only: phase, current Dutch price and pool price for every deployed pool.
contract StatusScript is AuctionScriptBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external view {
        string memory json = loadDeployment();
        ReopenAuctionHook hook = loadHook(json);
        uint256 n = poolCount(json);
        console2.log("block:", block.number);
        for (uint256 i; i < n; i++) {
            DeployedPool memory p = loadPool(json, i);
            PoolId id = p.key.toId();
            (uint160 sqrtP,,,) = hook.poolManager().getSlot0(id);
            (, uint64 endBlock,,,) = hook.auctions(id);
            bool live = hook.phase(id) == ReopenAuctionHook.Phase.AUCTION;
            console2.log(
                string.concat(
                    vm.toString(i),
                    " ",
                    p.label,
                    live ? " AUCTION" : " OPEN",
                    " price(raw bid ccy)=",
                    vm.toString(hook.currentPrice(id)),
                    " endBlock=",
                    vm.toString(uint256(endBlock)),
                    " sqrtPriceX96=",
                    vm.toString(uint256(sqrtP))
                )
            );
        }
    }
}
