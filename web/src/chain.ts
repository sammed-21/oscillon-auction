import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  parseAbi,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const RPC_URL: string = import.meta.env.VITE_RPC_URL ?? "http://localhost:8545";

/** Public anvil dev keys (never use on a real network). */
export const ANVIL_ACCOUNTS: { label: string; key: Hex }[] = [
  { label: "Keeper · anvil #0", key: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" },
  { label: "Bidder · anvil #1", key: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" },
  { label: "Trader · anvil #2", key: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" },
];

export const poolKeyType =
  "(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)" as const;

export const hookAbi = parseAbi([
  `function startAuction(${poolKeyType} key, uint160 refSqrtPriceX96) returns (uint256)`,
  `function bidAndSwap(${poolKeyType} key, (bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96) params, uint256 maxBid) returns (int256, uint256)`,
  `function estimateArbProfit(${poolKeyType} key, uint160 refSqrtPriceX96) view returns (uint256)`,
  "function auctions(bytes32 id) view returns (uint64 startBlock, uint64 endBlock, uint160 refSqrtPriceX96, uint256 startBid, bool active)",
  "function phase(bytes32 id) view returns (uint8)",
  "function currentPrice(bytes32 id) view returns (uint256)",
  "function auctionBlocks() view returns (uint64)",
  "event AuctionStarted(bytes32 indexed poolId, uint160 refSqrtPriceX96, uint256 startBid, uint64 startBlock, uint64 endBlock)",
  "event AuctionWon(bytes32 indexed poolId, address indexed winner, uint256 bid, address bidCurrency, int256 swapDelta)",
]);

export const erc20Abi = parseAbi([
  "function symbol() view returns (string)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function mint(address,uint256)",
]);

export const poolManagerAbi = parseAbi(["function extsload(bytes32 slot) view returns (bytes32)"]);

export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };

export type DeployedPool = {
  index: number;
  label: string;
  poolId: Hex;
  key: PoolKey;
  decimals0: number;
  decimals1: number;
  bidInCurrency0: boolean;
};

export type Deployment = { hook: Address; poolManager: Address; keeper: Address; pools: DeployedPool[] };

const deploymentFiles = import.meta.glob("../../deployments/*.json", { eager: true, import: "default" }) as Record<
  string,
  Record<string, any>
>;

export function loadDeployment(chainId: number): Deployment | undefined {
  const raw = Object.entries(deploymentFiles).find(([path]) => path.endsWith(`/${chainId}.json`))?.[1];
  if (!raw) return undefined;
  const pools: DeployedPool[] = [];
  for (let i = 0; i < Number(raw.poolCount); i++) {
    const p = raw[`pool${i}`];
    pools.push({
      index: i,
      label: p.label,
      poolId: p.poolId,
      key: {
        currency0: p.currency0,
        currency1: p.currency1,
        fee: Number(p.fee),
        tickSpacing: Number(p.tickSpacing),
        hooks: raw.hook,
      },
      decimals0: Number(p.decimals0),
      decimals1: Number(p.decimals1),
      bidInCurrency0: Boolean(p.bidInCurrency0),
    });
  }
  return { hook: raw.hook, poolManager: raw.poolManager, keeper: raw.keeper, pools };
}

export function makeChain(id: number): Chain {
  return defineChain({
    id,
    name: id === 31337 ? "Anvil" : `Chain ${id}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [RPC_URL] } },
  });
}

export const probeClient = createPublicClient({ transport: http(RPC_URL) });

export function makePublicClient(chain: Chain): PublicClient {
  return createPublicClient({ chain, transport: http(RPC_URL) }) as PublicClient;
}

export function makeLocalWallet(chain: Chain, key: Hex): WalletClient {
  return createWalletClient({ account: privateKeyToAccount(key), chain, transport: http(RPC_URL) });
}

export async function makeBrowserWallet(chain: Chain): Promise<WalletClient> {
  const eth = (window as any).ethereum;
  if (!eth) throw new Error("No browser wallet found");
  const [address] = await eth.request({ method: "eth_requestAccounts" });
  return createWalletClient({ account: address as Address, chain, transport: custom(eth) });
}

// ---------------------------------------------------------------------------
// Price math. Prices are currency1 per currency0 in whole tokens (Uniswap convention).
// ---------------------------------------------------------------------------

const Q96 = 2 ** 96;

export function sqrtToPrice(sqrtPriceX96: bigint, decimals0: number, decimals1: number): number {
  const s = Number(sqrtPriceX96) / Q96;
  return s * s * 10 ** (decimals0 - decimals1);
}

function bigSqrt(n: bigint): bigint {
  if (n < 2n) return n;
  let x = n;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
}

export function priceToSqrt(price: number, decimals0: number, decimals1: number): bigint {
  const priceE12 = BigInt(Math.round(price * 1e12));
  return bigSqrt((priceE12 * 10n ** BigInt(decimals1) * (1n << 192n)) / (10n ** 12n * 10n ** BigInt(decimals0)));
}

/** v4 StateLibrary: pools mapping lives at slot 6; slot0 packs sqrtPriceX96 in the low 160 bits. */
export function poolStateSlot(poolId: Hex): Hex {
  return keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, 6n]));
}

export function decodeSqrtPrice(slot0: Hex): bigint {
  return BigInt(slot0) & ((1n << 160n) - 1n);
}

export const MAX_EXACT_IN = -(2n ** 127n - 1n);
