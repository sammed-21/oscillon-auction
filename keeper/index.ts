/**
 * Reopen Auction keeper.
 *
 * Waits for the market to reopen (default NYSE: Mon-Fri 09:30 America/New_York), fetches each pool's
 * reference price, and calls `startAuction(key, refSqrtPriceX96)` on every pool. It then logs the
 * hook's AuctionStarted / AuctionWon events.
 *
 * Env:
 *   RPC_URL        default http://localhost:8545
 *   KEEPER_KEY     keeper private key (falls back to PRIVATE_KEY)
 *   DEPLOYMENTS    path to deployments/<chainId>.json (default: ../deployments/<chainId>.json)
 *   PRICES         path to a JSON file { "<poolIndex>": <price currency1 per currency0>, ... } (default: ./prices.json)
 *   OPEN_TIME      "HH:MM" in OPEN_TZ (default 09:30)
 *   OPEN_TZ        IANA timezone (default America/New_York)
 *
 * Flags:
 *   --now          skip the schedule and start auctions immediately (demo)
 *
 * The price source is `fetchRefPrices`. Swap it for an oracle / data API (or a Chainlink CRE workflow).
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
  parseAbi,
  formatUnits,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const here = dirname(fileURLToPath(import.meta.url));

const hookAbi = parseAbi([
  "function startAuction((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key, uint160 refSqrtPriceX96) returns (uint256)",
  "function estimateArbProfit((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key, uint160 refSqrtPriceX96) view returns (uint256)",
  "function phase(bytes32 id) view returns (uint8)",
  "function currentPrice(bytes32 id) view returns (uint256)",
  "event AuctionStarted(bytes32 indexed poolId, uint160 refSqrtPriceX96, uint256 startBid, uint64 startBlock, uint64 endBlock)",
  "event AuctionWon(bytes32 indexed poolId, address indexed winner, uint256 bid, address bidCurrency, int256 swapDelta)",
]);

type Pool = {
  index: number;
  label: string;
  poolId: Hex;
  key: { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
  decimals0: number;
  decimals1: number;
  bidInCurrency0: boolean;
};

// ---------------------------------------------------------------------------
// Price math (matches script/base/AuctionScriptBase.sol)
// ---------------------------------------------------------------------------

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

/** price = currency1 per currency0 in whole tokens -> sqrtPriceX96 (raw units). */
export function toSqrtPriceX96(price: number, decimals0: number, decimals1: number): bigint {
  const priceE6 = BigInt(Math.round(price * 1e6));
  const rawX192 = (priceE6 * 10n ** BigInt(decimals1) * (1n << 192n)) / (1_000_000n * 10n ** BigInt(decimals0));
  return bigSqrt(rawX192);
}

// ---------------------------------------------------------------------------
// Schedule
// ---------------------------------------------------------------------------

/** Milliseconds until the next weekday OPEN_TIME in OPEN_TZ. */
function msUntilNextOpen(openTime: string, tz: string, now = new Date()): number {
  const [hh, mm] = openTime.split(":").map(Number);
  for (let day = 0; day < 8; day++) {
    const candidate = new Date(now.getTime() + day * 86_400_000);
    const parts = Object.fromEntries(
      new Intl.DateTimeFormat("en-US", {
        timeZone: tz,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        weekday: "short",
        hour: "2-digit",
        minute: "2-digit",
        hourCycle: "h23",
      })
        .formatToParts(candidate)
        .map((p) => [p.type, p.value]),
    );
    if (parts.weekday === "Sat" || parts.weekday === "Sun") continue;
    // Offset of tz from UTC at this moment.
    const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute);
    const offsetMs = asUtc - Math.floor(candidate.getTime() / 60_000) * 60_000;
    const openUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, hh, mm) - offsetMs;
    if (openUtc > now.getTime()) return openUtc - now.getTime();
  }
  throw new Error("no open found in the next 8 days");
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

function loadPools(path: string): Pool[] {
  const d = JSON.parse(readFileSync(path, "utf8"));
  const pools: Pool[] = [];
  for (let i = 0; i < Number(d.poolCount); i++) {
    const p = d[`pool${i}`];
    pools.push({
      index: i,
      label: p.label,
      poolId: p.poolId,
      key: {
        currency0: p.currency0,
        currency1: p.currency1,
        fee: Number(p.fee),
        tickSpacing: Number(p.tickSpacing),
        hooks: d.hook,
      },
      decimals0: Number(p.decimals0),
      decimals1: Number(p.decimals1),
      bidInCurrency0: Boolean(p.bidInCurrency0),
    });
  }
  return pools;
}

/** Reference price per pool index. Replace with a real feed (oracle, data API, CRE). */
async function fetchRefPrices(path: string): Promise<Record<string, number>> {
  return JSON.parse(readFileSync(path, "utf8"));
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const rpc = process.env.RPC_URL ?? "http://localhost:8545";
  const key = (process.env.KEEPER_KEY ?? process.env.PRIVATE_KEY) as Hex | undefined;
  if (!key) throw new Error("set KEEPER_KEY or PRIVATE_KEY");

  const probe = createPublicClient({ transport: http(rpc) });
  const chainId = await probe.getChainId();
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(rpc) });
  const account = privateKeyToAccount(key);
  const wallet = createWalletClient({ account, chain, transport: http(rpc) });

  const deploymentsPath = process.env.DEPLOYMENTS ?? resolve(here, `../deployments/${chainId}.json`);
  const pricesPath = process.env.PRICES ?? resolve(here, "prices.json");
  const pools = loadPools(deploymentsPath);
  const hook = pools[0]?.key.hooks;
  if (!hook) throw new Error(`no pools in ${deploymentsPath}`);

  console.log(`keeper ${account.address} on chain ${chainId}, hook ${hook}, ${pools.length} pools`);

  // Log auction events as they happen.
  publicClient.watchContractEvent({
    address: hook,
    abi: hookAbi,
    onLogs: (logs) => {
      for (const log of logs) {
        const pool = pools.find((p) => p.poolId.toLowerCase() === String(log.args.poolId).toLowerCase());
        const label = pool?.label ?? log.args.poolId;
        if (log.eventName === "AuctionStarted") {
          console.log(`[event] ${label} AuctionStarted startBid=${log.args.startBid} blocks ${log.args.startBlock}..${log.args.endBlock}`);
        } else if (log.eventName === "AuctionWon") {
          console.log(`[event] ${label} AuctionWon winner=${log.args.winner} bid=${log.args.bid} -> LPs`);
        }
      }
    },
  });

  if (!process.argv.includes("--now")) {
    const openTime = process.env.OPEN_TIME ?? "09:30";
    const tz = process.env.OPEN_TZ ?? "America/New_York";
    const wait = msUntilNextOpen(openTime, tz);
    console.log(`waiting ${(wait / 3_600_000).toFixed(2)}h for ${openTime} ${tz}`);
    await new Promise((r) => setTimeout(r, wait));
  }

  const prices = await fetchRefPrices(pricesPath);
  for (const pool of pools) {
    const price = prices[String(pool.index)];
    if (price === undefined) {
      console.log(`${pool.label}: no reference price, skipping`);
      continue;
    }
    const phase = await publicClient.readContract({ address: hook, abi: hookAbi, functionName: "phase", args: [pool.poolId] });
    if (phase === 1) {
      console.log(`${pool.label}: auction already live, skipping`);
      continue;
    }
    const ref = toSqrtPriceX96(price, pool.decimals0, pool.decimals1);
    const estimate = await publicClient.readContract({
      address: hook,
      abi: hookAbi,
      functionName: "estimateArbProfit",
      args: [pool.key, ref],
    });
    const bidDecimals = pool.bidInCurrency0 ? pool.decimals0 : pool.decimals1;
    const hash = await wallet.writeContract({ address: hook, abi: hookAbi, functionName: "startAuction", args: [pool.key, ref] });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(
      `${pool.label}: startAuction @ ${price} (arb estimate ${formatUnits(estimate, bidDecimals)}) tx ${hash} status ${receipt.status}`,
    );
  }

  console.log("auctions started; watching events (Ctrl+C to exit)");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
