import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { formatUnits, maxUint256, type Address, type Hex, type PublicClient, type WalletClient } from "viem";
import {
  ANVIL_ACCOUNTS,
  MAX_EXACT_IN,
  RPC_URL,
  decodeSqrtPrice,
  erc20Abi,
  hookAbi,
  loadDeployment,
  makeBrowserWallet,
  makeChain,
  makeLocalWallet,
  makePublicClient,
  poolManagerAbi,
  poolStateSlot,
  priceToSqrt,
  probeClient,
  sqrtToPrice,
  type DeployedPool,
  type Deployment,
} from "./chain";
import { ComparisonChart, fmt, replayRows, replayTotals } from "./replay";

type PoolState = {
  phase: number; // 0 OPEN, 1 AUCTION
  price: bigint; // current Dutch price, raw bid currency
  startBlock: bigint;
  endBlock: bigint;
  ref: bigint;
  startBid: bigint;
  sqrtPrice: bigint;
};

type Win = { poolId: Hex; bid: bigint; winner: Address; block: bigint };
type Activity = { id: string; block: bigint; text: string; kind: "start" | "win" | "info" };

const POLL_MS = 1500;

export function App() {
  const [chainId, setChainId] = useState<number>();
  const [rpcError, setRpcError] = useState<string>();
  const [block, setBlock] = useState<bigint>(0n);
  const [states, setStates] = useState<Record<string, PoolState>>({});
  const [symbols, setSymbols] = useState<Record<string, string>>({});
  const [wins, setWins] = useState<Record<string, Win>>({});
  const [activity, setActivity] = useState<Activity[]>([]);
  const [accountIdx, setAccountIdx] = useState<number>(1); // bidder by default
  const [browserWallet, setBrowserWallet] = useState<WalletClient>();
  const [busy, setBusy] = useState<string>();
  const [toast, setToast] = useState<{ text: string; error?: boolean }>();
  const lastLogBlock = useRef<bigint>(-1n);

  // Connect to the RPC once.
  useEffect(() => {
    probeClient
      .getChainId()
      .then(setChainId)
      .catch(() => setRpcError(`Cannot reach ${RPC_URL}`));
  }, []);

  const chain = useMemo(() => (chainId ? makeChain(chainId) : undefined), [chainId]);
  const client = useMemo<PublicClient | undefined>(() => (chain ? makePublicClient(chain) : undefined), [chain]);
  const deployment = useMemo<Deployment | undefined>(() => (chainId ? loadDeployment(chainId) : undefined), [chainId]);
  const isLocal = chainId === 31337;

  const wallet = useMemo<WalletClient | undefined>(() => {
    if (!chain) return undefined;
    if (accountIdx === -1) return browserWallet;
    return isLocal ? makeLocalWallet(chain, ANVIL_ACCOUNTS[accountIdx].key) : undefined;
  }, [chain, accountIdx, browserWallet, isLocal]);

  const poolById = useMemo(() => {
    const m: Record<string, DeployedPool> = {};
    deployment?.pools.forEach((p) => (m[p.poolId.toLowerCase()] = p));
    return m;
  }, [deployment]);

  // Token symbols, once.
  useEffect(() => {
    if (!client || !deployment) return;
    const tokens = [...new Set(deployment.pools.flatMap((p) => [p.key.currency0, p.key.currency1]))];
    Promise.all(
      tokens.map((t) =>
        client
          .readContract({ address: t, abi: erc20Abi, functionName: "symbol" })
          .then((s) => [t.toLowerCase(), s] as const)
          .catch(() => [t.toLowerCase(), t.slice(0, 6)] as const),
      ),
    ).then((entries) => setSymbols(Object.fromEntries(entries)));
  }, [client, deployment]);

  // Poll chain state + events.
  const refresh = useCallback(async () => {
    if (!client || !deployment) return;
    const [bn, ...poolStates] = await Promise.all([
      client.getBlockNumber(),
      ...deployment.pools.map(async (p) => {
        const [phase, price, auction, slot0] = await Promise.all([
          client.readContract({ address: deployment.hook, abi: hookAbi, functionName: "phase", args: [p.poolId] }),
          client.readContract({ address: deployment.hook, abi: hookAbi, functionName: "currentPrice", args: [p.poolId] }),
          client.readContract({ address: deployment.hook, abi: hookAbi, functionName: "auctions", args: [p.poolId] }),
          client.readContract({
            address: deployment.poolManager,
            abi: poolManagerAbi,
            functionName: "extsload",
            args: [poolStateSlot(p.poolId)],
          }),
        ]);
        const [startBlock, endBlock, ref, startBid] = auction;
        return [
          p.poolId.toLowerCase(),
          { phase: Number(phase), price, startBlock, endBlock, ref, startBid, sqrtPrice: decodeSqrtPrice(slot0) },
        ] as const;
      }),
    ]);
    setBlock(bn);
    setStates(Object.fromEntries(poolStates));

    if (bn > lastLogBlock.current) {
      const fromBlock = lastLogBlock.current + 1n;
      lastLogBlock.current = bn;
      const logs = await client.getContractEvents({ address: deployment.hook, abi: hookAbi, fromBlock, toBlock: bn });
      if (logs.length) {
        const newWins: Record<string, Win> = {};
        const items: Activity[] = [];
        for (const log of logs) {
          const pool = poolById[String(log.args.poolId).toLowerCase()];
          if (!pool) continue;
          const bidDec = pool.bidInCurrency0 ? pool.decimals0 : pool.decimals1;
          if (log.eventName === "AuctionStarted") {
            items.push({
              id: `${log.transactionHash}-${log.logIndex}`,
              block: log.blockNumber!,
              kind: "start",
              text: `${pool.label} locked · auction opens at ${fmt(Number(formatUnits(log.args.startBid!, bidDec)))}`,
            });
          } else if (log.eventName === "AuctionWon") {
            newWins[pool.poolId.toLowerCase()] = {
              poolId: pool.poolId,
              bid: log.args.bid!,
              winner: log.args.winner!,
              block: log.blockNumber!,
            };
            items.push({
              id: `${log.transactionHash}-${log.logIndex}`,
              block: log.blockNumber!,
              kind: "win",
              text: `${pool.label} won by ${short(log.args.winner!)} · ${fmt(Number(formatUnits(log.args.bid!, bidDec)))} paid to LPs`,
            });
          }
        }
        if (Object.keys(newWins).length) setWins((w) => ({ ...w, ...newWins }));
        if (items.length) setActivity((a) => [...items.reverse(), ...a].slice(0, 30));
      }
    }
  }, [client, deployment, poolById]);

  useEffect(() => {
    if (!client || !deployment) return;
    refresh().catch(() => {});
    const t = setInterval(() => refresh().catch(() => {}), POLL_MS);
    return () => clearInterval(t);
  }, [client, deployment, refresh]);

  const notify = (text: string, error = false) => {
    setToast({ text, error });
    setTimeout(() => setToast(undefined), 5000);
  };

  async function run(label: string, fn: () => Promise<void>) {
    setBusy(label);
    try {
      await fn();
      await refresh();
    } catch (e: any) {
      notify(e?.shortMessage ?? e?.message ?? String(e), true);
    } finally {
      setBusy(undefined);
    }
  }

  async function send(args: Parameters<WalletClient["writeContract"]>[0]) {
    if (!wallet || !client) throw new Error("Connect an account first");
    const hash = await wallet.writeContract({ ...args, account: wallet.account!, chain } as any);
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`Transaction reverted: ${hash}`);
    return receipt;
  }

  const startAuction = (pool: DeployedPool, refPrice: number) =>
    run(`start-${pool.index}`, async () => {
      const ref = priceToSqrt(refPrice, pool.decimals0, pool.decimals1);
      await send({ address: deployment!.hook, abi: hookAbi, functionName: "startAuction", args: [pool.key, ref] } as any);
      notify(`${pool.label}: market reopened at ${refPrice}. Pool locked, auction live.`);
    });

  /** Mint (local mocks only) and approve the hook for a token, if needed. Returns true if it sent a tx. */
  async function ensureToken(token: Address, me: Address) {
    let sent = false;
    if (isLocal) {
      const bal = await client!.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [me] });
      if (bal < 10n ** 30n) {
        await send({ address: token, abi: erc20Abi, functionName: "mint", args: [me, 10n ** 32n] } as any);
        sent = true;
      }
    }
    const allowance = await client!.readContract({
      address: token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [me, deployment!.hook],
    });
    if (allowance < 2n ** 200n) {
      await send({ address: token, abi: erc20Abi, functionName: "approve", args: [deployment!.hook, maxUint256] } as any);
      sent = true;
    }
    return sent;
  }

  // On a local chain every tx mines a block, so set up the account before any auction starts.
  // Otherwise the mint/approve txs would eat auction blocks and the bid would land far below the clicked price.
  const prepared = useRef<Set<string>>(new Set());
  useEffect(() => {
    if (!isLocal || !wallet || !deployment || !client) return;
    const me = wallet.account!.address;
    if (prepared.current.has(me)) return;
    prepared.current.add(me);
    const tokens = [...new Set(deployment.pools.flatMap((p) => [p.key.currency0, p.key.currency1]))];
    run("prepare", async () => {
      for (const t of tokens) await ensureToken(t, me);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isLocal, wallet, deployment, client]);

  const bid = (pool: DeployedPool) =>
    run(`bid-${pool.index}`, async () => {
      const st = states[pool.poolId.toLowerCase()];
      if (!st || st.phase !== 1) throw new Error("No live auction");
      const me = wallet!.account!.address;
      for (const token of [pool.key.currency0, pool.key.currency1]) await ensureToken(token, me);
      // The price only falls, so today's price is a safe cap for the block this lands in.
      const maxBid = await client!.readContract({
        address: deployment!.hook,
        abi: hookAbi,
        functionName: "currentPrice",
        args: [pool.poolId],
      });
      const params = { zeroForOne: st.ref < st.sqrtPrice, amountSpecified: MAX_EXACT_IN, sqrtPriceLimitX96: st.ref };
      await send({ address: deployment!.hook, abi: hookAbi, functionName: "bidAndSwap", args: [pool.key, params, maxBid] } as any);
      notify(`${pool.label}: auction won. Pool arbed to the reopen price, bid paid to LPs.`);
    });

  const mine = (n = 1) =>
    run("mine", async () => {
      for (let i = 0; i < n; i++) await (client as any).request({ method: "evm_mine", params: [] });
    });

  const connectBrowser = async () => {
    if (!chain) return;
    try {
      setBrowserWallet(await makeBrowserWallet(chain));
      setAccountIdx(-1);
    } catch (e: any) {
      notify(e?.message ?? String(e), true);
    }
  };

  const totals = replayTotals(replayRows);
  const live = deployment?.pools.filter((p) => states[p.poolId.toLowerCase()]?.phase === 1).length ?? 0;

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="mark" aria-hidden>
            ◐
          </span>
          <span className="wordmark">Reopen</span>
          <span className="tag">auction hook · Uniswap v4</span>
        </div>
        <div className="topbar-right">
          <span className="pill">
            <i className={`dot ${chainId ? "ok" : "bad"}`} />
            {chainId ? `${makeChain(chainId).name} · #${block.toString()}` : rpcError ?? "Connecting…"}
          </span>
          {busy === "prepare" && <span className="pill">Preparing account…</span>}
          {isLocal && (
            <button className="btn ghost sm" onClick={() => mine(1)} disabled={!!busy}>
              Mine block
            </button>
          )}
          <select
            className="select"
            value={accountIdx}
            onChange={(e) => {
              const v = Number(e.target.value);
              if (v === -1 && !browserWallet) connectBrowser();
              else setAccountIdx(v);
            }}
          >
            {isLocal && ANVIL_ACCOUNTS.map((a, i) => <option key={a.key} value={i}>{a.label}</option>)}
            <option value={-1}>{browserWallet ? `Wallet · ${short(browserWallet.account!.address)}` : "Connect browser wallet"}</option>
          </select>
        </div>
      </header>

      <section className="hero">
        <p className="eyebrow">Market reopen · first swap auction</p>
        <h1>
          The opening gap belongs <em>to LPs</em>, not the fastest bot.
        </h1>
        <p className="lede">
          When the underlying market reopens, the hook locks the pool and runs a Dutch auction for the first swap. The
          winner arbs the pool to the reopen price, and the winning bid is donated to the LPs in range.
        </p>
        <div className="stats">
          <Stat k="Recaptured for LPs" v={`${fmt(totals.recaptured * 100, 1)}%`} accent />
          <Stat k="Arb extracted, vanilla" v={fmt(totals.vanillaArb)} />
          <Stat k="Returned to LPs, auction" v={fmt(totals.bids)} />
          <Stat k="Live auctions" v={String(live)} />
        </div>
      </section>

      {!deployment && chainId && (
        <div className="card empty">
          No deployment for chain {chainId}. Run <code>forge script script/Deploy.s.sol --broadcast</code> to create{" "}
          <code>deployments/{chainId}.json</code>.
        </div>
      )}

      {deployment && (
        <section>
          <div className="section-head">
            <h2>Pools</h2>
            <span className="muted">
              Hook <code>{short(deployment.hook)}</code> · {deployment.pools.length} pools
            </span>
          </div>
          <div className="grid">
            {deployment.pools.map((p) => (
              <PoolCard
                key={p.poolId}
                pool={p}
                state={states[p.poolId.toLowerCase()]}
                block={block}
                win={wins[p.poolId.toLowerCase()]}
                symbols={symbols}
                busy={busy}
                canAct={!!wallet}
                onStart={(price) => startAuction(p, price)}
                onBid={() => bid(p)}
              />
            ))}
          </div>
        </section>
      )}

      <section className="split">
        <div>
          <div className="section-head">
            <h2>Vanilla vs auction</h2>
            <span className="muted">{totals.events} replayed reopens</span>
          </div>
          <ComparisonChart />
        </div>
        <div>
          <div className="section-head">
            <h2>Activity</h2>
          </div>
          <div className="card feed">
            {activity.length === 0 && <p className="muted">Waiting for AuctionStarted / AuctionWon…</p>}
            {activity.map((a) => (
              <div key={a.id} className={`feed-row ${a.kind}`}>
                <span className="feed-block">#{a.block.toString()}</span>
                <span>{a.text}</span>
              </div>
            ))}
          </div>
        </div>
      </section>

      <footer className="foot">
        <span>Reopen Auction Hook · ETHGlobal</span>
        <span className="muted">RPC {RPC_URL}</span>
      </footer>

      {toast && <div className={`toast ${toast.error ? "error" : ""}`}>{toast.text}</div>}
    </div>
  );
}

function Stat({ k, v, accent }: { k: string; v: string; accent?: boolean }) {
  return (
    <div className="stat card">
      <span className="k">{k}</span>
      <span className={`v ${accent ? "accent" : ""}`}>{v}</span>
    </div>
  );
}

function PoolCard(props: {
  pool: DeployedPool;
  state?: PoolState;
  block: bigint;
  win?: Win;
  symbols: Record<string, string>;
  busy?: string;
  canAct: boolean;
  onStart: (price: number) => void;
  onBid: () => void;
}) {
  const { pool, state, block, win, symbols, busy, canAct } = props;
  const sym0 = symbols[pool.key.currency0.toLowerCase()] ?? "currency0";
  const sym1 = symbols[pool.key.currency1.toLowerCase()] ?? "currency1";
  const bidSym = pool.bidInCurrency0 ? sym0 : sym1;
  const bidDec = pool.bidInCurrency0 ? pool.decimals0 : pool.decimals1;
  const poolPrice = state ? sqrtToPrice(state.sqrtPrice, pool.decimals0, pool.decimals1) : 0;
  const isAuction = state?.phase === 1;
  const [refInput, setRefInput] = useState<string>("");

  useEffect(() => {
    if (!refInput && poolPrice) setRefInput(roundSig(poolPrice * 1.04));
  }, [poolPrice, refInput]);

  const blocksLeft = isAuction && state ? Number(state.endBlock - block) : 0;
  const total = state ? Number(state.endBlock - state.startBlock) : 0;
  const elapsed = isAuction ? total - blocksLeft : 0;
  const priceNum = state ? Number(formatUnits(state.price, bidDec)) : 0;
  const startNum = state ? Number(formatUnits(state.startBid, bidDec)) : 0;

  return (
    <article className={`card pool ${isAuction ? "live" : ""}`}>
      <div className="pool-head">
        <div>
          <div className="pool-label">{pool.label}</div>
          <div className="pool-pair">
            {sym0} / {sym1} · {(pool.key.fee / 10_000).toFixed(2)}%
          </div>
        </div>
        <span className={`badge ${isAuction ? "auction" : "open"}`}>
          <i className="dot" />
          {isAuction ? "AUCTION" : "OPEN"}
        </span>
      </div>

      <div className="pool-price">
        <span className="k">Pool price</span>
        <span className="mono">
          {state ? roundSig(poolPrice) : "…"} <span className="faint">{sym1}/{sym0}</span>
        </span>
      </div>

      {isAuction && state ? (
        <>
          <div className="dutch">
            <span className="k">Dutch price · falls each block</span>
            <span className="dutch-price">
              {fmt(priceNum)} <span className="unit">{bidSym}</span>
            </span>
            <DecayCurve total={total} elapsed={elapsed} />
            <div className="dutch-meta">
              <span>start {fmt(startNum)}</span>
              <span>
                {blocksLeft} block{blocksLeft === 1 ? "" : "s"} left · reopen{" "}
                {roundSig(sqrtToPrice(state.ref, pool.decimals0, pool.decimals1))}
              </span>
            </div>
          </div>
          <button className="btn primary" disabled={!canAct || !!busy} onClick={props.onBid}>
            {busy === `bid-${pool.index}` ? "Bidding…" : `Bid ${fmt(priceNum)} ${bidSym} & arb`}
          </button>
        </>
      ) : (
        <div className="reopen">
          <label className="k" htmlFor={`ref-${pool.index}`}>
            Reopen price (keeper)
          </label>
          <div className="row">
            <input
              id={`ref-${pool.index}`}
              className="input mono"
              value={refInput}
              inputMode="decimal"
              onChange={(e) => setRefInput(e.target.value)}
            />
            <button
              className="btn"
              disabled={!canAct || !!busy || !(Number(refInput) > 0)}
              onClick={() => props.onStart(Number(refInput))}
            >
              {busy === `start-${pool.index}` ? "Locking…" : "Start auction"}
            </button>
          </div>
        </div>
      )}

      {win && (
        <div className="won">
          Bid → LPs: <strong>{fmt(Number(formatUnits(win.bid, bidDec)))} {bidSym}</strong>
          <span className="faint"> · #{win.block.toString()} · {short(win.winner)}</span>
        </div>
      )}
    </article>
  );
}

/** Linear Dutch decay with the current block marked. */
function DecayCurve({ total, elapsed }: { total: number; elapsed: number }) {
  const W = 260;
  const H = 54;
  const steps = Math.max(total, 1);
  const pts = Array.from({ length: steps + 1 }, (_, i) => [(i / steps) * W, 4 + ((i / steps) * (H - 8))]);
  const path = pts.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const cx = (Math.min(elapsed, steps) / steps) * W;
  const cy = 4 + (Math.min(elapsed, steps) / steps) * (H - 8);
  return (
    <svg viewBox={`-6 0 ${W + 12} ${H}`} className="decay" aria-hidden>
      {pts.map(([x], i) => (
        <line key={i} x1={x} x2={x} y1={0} y2={H} className="tick" />
      ))}
      <path d={path} className="decay-line" />
      <path d={`M0,4 L${cx.toFixed(1)},${cy.toFixed(1)}`} className="decay-done" />
      <circle cx={cx} cy={cy} r={4.5} className="decay-dot" />
    </svg>
  );
}

function short(a: string) {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

function roundSig(n: number) {
  if (!n) return "0";
  const digits = n >= 100 ? 2 : n >= 1 ? 4 : 6;
  return Number(n.toFixed(digits)).toString();
}
