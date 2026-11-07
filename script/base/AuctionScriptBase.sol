// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ReopenAuctionHook} from "../../src/ReopenAuctionHook.sol";

/// @notice Shared helpers for the keeper / bidder / status scripts. Reads deployments/<chainId>.json.
abstract contract AuctionScriptBase is Script {
    using stdJson for string;

    struct DeployedPool {
        string label;
        PoolKey key;
        uint8 decimals0;
        uint8 decimals1;
        bool bidInCurrency0;
    }

    function deploymentsPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function loadDeployment() internal view returns (string memory) {
        return vm.readFile(deploymentsPath());
    }

    function loadHook(string memory json) internal pure returns (ReopenAuctionHook) {
        return ReopenAuctionHook(json.readAddress(".hook"));
    }

    function poolCount(string memory json) internal pure returns (uint256) {
        return json.readUint(".poolCount");
    }

    function loadPool(string memory json, uint256 i) internal pure returns (DeployedPool memory p) {
        string memory k = string.concat(".pool", vm.toString(i));
        p.label = json.readString(string.concat(k, ".label"));
        p.key = PoolKey({
            currency0: Currency.wrap(json.readAddress(string.concat(k, ".currency0"))),
            currency1: Currency.wrap(json.readAddress(string.concat(k, ".currency1"))),
            fee: uint24(json.readUint(string.concat(k, ".fee"))),
            tickSpacing: int24(int256(json.readUint(string.concat(k, ".tickSpacing")))),
            hooks: IHooks(json.readAddress(".hook"))
        });
        p.decimals0 = uint8(json.readUint(string.concat(k, ".decimals0")));
        p.decimals1 = uint8(json.readUint(string.concat(k, ".decimals1")));
        p.bidInCurrency0 = json.readBool(string.concat(k, ".bidInCurrency0"));
    }

    /// @notice sqrtPriceX96 for a price in currency1 per currency0 (whole tokens), scaled by 1e6.
    function sqrtPriceFromE6(uint256 priceE6, uint8 decimals0, uint8 decimals1) internal pure returns (uint160) {
        uint256 rawX192 = Math.mulDiv(priceE6 * 10 ** decimals1, 1 << 192, 1e6 * 10 ** decimals0);
        return uint160(Math.sqrt(rawX192));
    }

    /// @dev Private key from env var `name`, falling back to PRIVATE_KEY.
    ///      On anvil, missing keys default to the public dev accounts: #0 for the keeper, #1 for the bidder.
    function keyOr(string memory name) internal view returns (uint256) {
        if (block.chainid == 31337) {
            uint256 dev = keccak256(bytes(name)) == keccak256("BIDDER_KEY")
                ? 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
                : 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
            return vm.envOr(name, vm.envOr("PRIVATE_KEY", dev));
        }
        return vm.envOr(name, vm.envUint("PRIVATE_KEY"));
    }
}
