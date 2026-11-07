// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Deployers} from "test/utils/Deployers.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ReopenAuctionHook} from "../src/ReopenAuctionHook.sol";

/// @notice Deploys the hook (address mined with HookMiner), one mock token pair + pool per config entry,
///         and full-range liquidity. Writes deployments/<chainId>.json.
/// @dev Env:
///        PRIVATE_KEY          deployer (owner of the hook, LP)
///        KEEPER               keeper address (default: deployer)
///        PAIRS_CONFIG         pairs file (default: replay/gaps.json; uses closesE6[0] as the initial price)
///        AUCTION_BLOCKS       Dutch auction length (default 10)
///        START_PREMIUM_BPS    start price multiplier on the arb estimate (default 15000 = 1.5x)
///      On anvil (31337) the Uniswap v4 contracts are deployed too; elsewhere hookmate's canonical addresses are used.
contract DeployScript is Script, Deployers {
    using stdJson for string;

    address deployer;
    string root = "root";

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
        address keeper = vm.envOr("KEEPER", deployer);
        uint64 auctionBlocks = uint64(vm.envOr("AUCTION_BLOCKS", uint256(10)));
        uint32 premiumBps = uint32(vm.envOr("START_PREMIUM_BPS", uint256(15_000)));
        string memory cfg = vm.readFile(vm.envOr("PAIRS_CONFIG", string("replay/gaps.json")));

        vm.startBroadcast(pk);
        deployArtifacts();

        // Mine and deploy the hook.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory args = abi.encode(poolManager, deployer, keeper, auctionBlocks, premiumBps);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(ReopenAuctionHook).creationCode, args);
        ReopenAuctionHook hook =
            new ReopenAuctionHook{salt: salt}(poolManager, deployer, keeper, auctionBlocks, premiumBps);
        require(address(hook) == hookAddr, "hook address mismatch");

        uint256 n;
        for (; cfg.keyExists(string.concat(".pairs[", vm.toString(n), "]")); n++) {
            _deployPool(cfg, n, hook);
        }
        vm.stopBroadcast();

        vm.serializeAddress(root, "poolManager", address(poolManager));
        vm.serializeAddress(root, "positionManager", address(positionManager));
        vm.serializeAddress(root, "permit2", address(permit2));
        vm.serializeAddress(root, "keeper", keeper);
        vm.serializeUint(root, "poolCount", n);
        string memory out = vm.serializeAddress(root, "hook", address(hook));
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);

        console2.log("hook:", address(hook));
        console2.log("pools:", n);
        console2.log("written:", path);
    }

    struct PairCfg {
        string label;
        uint8 d0;
        uint8 d1;
        bool bidIn0;
        uint24 fee;
        int24 tickSpacing;
        uint256 priceE6;
        uint256 liquidityValue1;
    }

    function _readPair(string memory cfg, uint256 i) internal pure returns (PairCfg memory c) {
        string memory k = string.concat(".pairs[", vm.toString(i), "]");
        c.label = cfg.readString(string.concat(k, ".label"));
        c.d0 = uint8(cfg.readUint(string.concat(k, ".decimals0")));
        c.d1 = uint8(cfg.readUint(string.concat(k, ".decimals1")));
        c.bidIn0 = cfg.readBool(string.concat(k, ".bidInCurrency0"));
        c.fee = uint24(cfg.readUint(string.concat(k, ".fee")));
        c.tickSpacing = int24(int256(cfg.readUint(string.concat(k, ".tickSpacing"))));
        c.priceE6 = cfg.readUintArray(string.concat(k, ".closesE6"))[0];
        c.liquidityValue1 = cfg.readUint(string.concat(k, ".liquidityValue1"));
    }

    function _deployPool(string memory cfg, uint256 i, ReopenAuctionHook hook) internal {
        PairCfg memory c = _readPair(cfg, i);
        (Currency c0, Currency c1) = _deployPair(c.label, c.d0, c.d1, c.liquidityValue1);
        PoolKey memory key = PoolKey(c0, c1, c.fee, c.tickSpacing, IHooks(address(hook)));

        uint160 sqrtPrice = uint160(Math.sqrt(Math.mulDiv(c.priceE6 * 10 ** c.d1, 1 << 192, 1e6 * 10 ** c.d0)));
        poolManager.initialize(key, sqrtPrice);
        if (c.bidIn0) hook.setBidCurrency(key, true);

        uint256 tokenId = _addFullRange(key, sqrtPrice, c);
        _writePool(i, c, key, tokenId);
        console2.log(c.label, Currency.unwrap(c0), Currency.unwrap(c1));
    }

    function _addFullRange(PoolKey memory key, uint160 sqrtPrice, PairCfg memory c) internal returns (uint256 tokenId) {
        uint128 liquidity = uint128(Math.mulDiv(c.liquidityValue1 * 10 ** c.d1 / 2, 1 << 96, sqrtPrice));
        int24 lower = TickMath.minUsableTick(c.tickSpacing);
        int24 upper = TickMath.maxUsableTick(c.tickSpacing);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPrice, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lower, upper, uint256(liquidity), a0 + 1, a1 + 1, deployer, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp + 600
        );
    }

    function _writePool(uint256 i, PairCfg memory c, PoolKey memory key, uint256 tokenId) internal {
        string memory obj = string.concat("pool", vm.toString(i));
        vm.serializeString(obj, "label", c.label);
        vm.serializeAddress(obj, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(obj, "currency1", Currency.unwrap(key.currency1));
        vm.serializeUint(obj, "decimals0", c.d0);
        vm.serializeUint(obj, "decimals1", c.d1);
        vm.serializeUint(obj, "fee", c.fee);
        vm.serializeUint(obj, "tickSpacing", uint256(int256(c.tickSpacing)));
        vm.serializeBool(obj, "bidInCurrency0", c.bidIn0);
        vm.serializeUint(obj, "lpTokenId", tokenId);
        vm.serializeBytes32(obj, "poolId", keccak256(abi.encode(key)));
        string memory poolJson = vm.serializeUint(obj, "initialPriceE6", c.priceE6);
        vm.serializeString(root, obj, poolJson);
    }

    /// @dev Deploys two mock tokens so that the lower address (currency0) gets `d0` decimals.
    function _deployPair(string memory label, uint8 d0, uint8 d1, uint256 liquidityValue1)
        internal
        returns (Currency, Currency)
    {
        uint64 nonce = vm.getNonce(deployer);
        bool firstIsLower = vm.computeCreateAddress(deployer, nonce) < vm.computeCreateAddress(deployer, nonce + 1);
        MockERC20 first = new MockERC20(
            string.concat(label, firstIsLower ? " currency0" : " currency1"),
            string.concat(label, firstIsLower ? "-C0" : "-C1"),
            firstIsLower ? d0 : d1
        );
        MockERC20 second = new MockERC20(
            string.concat(label, firstIsLower ? " currency1" : " currency0"),
            string.concat(label, firstIsLower ? "-C1" : "-C0"),
            firstIsLower ? d1 : d0
        );
        (MockERC20 t0, MockERC20 t1) = firstIsLower ? (first, second) : (second, first);
        require(address(t0) < address(t1), "token order");

        // Generous supply: liquidity plus room for keeper/bidder demos.
        uint256 supply1 = liquidityValue1 * 10 ** d1 * 1000;
        t0.mint(deployer, 10 ** (d0 + 15));
        t1.mint(deployer, supply1);
        _approveForLp(t0);
        _approveForLp(t1);
        return (Currency.wrap(address(t0)), Currency.wrap(address(t1)));
    }

    function _approveForLp(MockERC20 token) internal {
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
    }

    function _etch(address target, bytes memory bytecode) internal override {
        if (block.chainid == 31337) {
            vm.etch(target, bytecode); // local simulation
            vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '","', vm.toString(bytecode), '"]'));
        } else {
            revert("Unsupported etch on this network");
        }
    }
}
