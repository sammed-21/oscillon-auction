import { useMemo, useState } from "react";
import resultsCsv from "../../replay/results.csv?raw";

export type ReplayRow = {
  pair: string;
  event: number;
  close: number;
  open: number;
  gapBps: number;
  vanillaArb: number;
  vanillaLp: number;
  bid: number;
  winnerProfit: number;
  auctionLp: number;
  bidBlock: number | null;
};

export function parseReplay(csv: string): ReplayRow[] {
  const [header, ...lines] = csv.trim().split("\n");
  if (!header) return [];
  return lines.map((line) => {
    const c = line.split(",");
    return {
      pair: c[0],
      event: Number(c[1]),
      close: Number(c[2]),
      open: Number(c[3]),
      gapBps: Number(c[4]),
      vanillaArb: Number(c[5]),
      vanillaLp: Number(c[6]),
      bid: Number(c[7]),
      winnerProfit: Number(c[8]),
      auctionLp: Number(c[9]),
      bidBlock: c[10] ? Number(c[10]) : null,
    };
  });
}

export const replayRows = parseReplay(resultsCsv);

export function replayTotals(rows: ReplayRow[]) {
  const sum = (f: (r: ReplayRow) => number) => rows.reduce((a, r) => a + f(r), 0);
  const vanillaArb = sum((r) => r.vanillaArb);
  const bids = sum((r) => r.bid);
  return {
    events: rows.length,
    vanillaArb,
    vanillaLp: sum((r) => r.vanillaLp),
    bids,
    auctionLp: sum((r) => r.auctionLp),
    winnerProfit: sum((r) => r.winnerProfit),
    recaptured: vanillaArb > 0 ? bids / vanillaArb : 0,
  };
}

export const fmt = (n: number, digits = 2) =>
  n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });

/** Grouped bars per reopen event: what the arb kept in a vanilla pool vs what LPs got back from the auction. */
export function ComparisonChart() {
  const pairs = useMemo(() => [...new Set(replayRows.map((r) => r.pair))], []);
  const [pair, setPair] = useState<string>("all");

  const rows = pair === "all" ? replayRows : replayRows.filter((r) => r.pair === pair);
  const t = replayTotals(rows);

  // In "all" mode, aggregate per pair; otherwise per event.
  const groups =
    pair === "all"
      ? pairs.map((p) => {
          const pt = replayTotals(replayRows.filter((r) => r.pair === p));
          return { label: p, a: pt.vanillaArb, b: pt.bids, sub: `${fmt(pt.recaptured * 100, 0)}%` };
        })
      : rows.map((r) => ({
          label: `#${r.event}`,
          a: r.vanillaArb,
          b: r.bid,
          sub: `${r.gapBps >= 0 ? "+" : ""}${fmt(r.gapBps / 100, 1)}%`,
        }));

  const max = Math.max(1, ...groups.flatMap((g) => [g.a, g.b]));
  const W = 720;
  const H = 240;
  const padL = 8;
  const padB = 40;
  const gw = (W - padL) / Math.max(groups.length, 1);
  const bw = Math.min(26, gw * 0.32);

  if (replayRows.length === 0) {
    return <p className="muted">No replay results yet. Run <code>forge test --match-contract ReplayTest</code>.</p>;
  }

  return (
    <div className="chart-card card">
      <div className="chart-head">
        <div className="tabs" role="tablist">
          {["all", ...pairs].map((p) => (
            <button key={p} className={`tab ${p === pair ? "active" : ""}`} onClick={() => setPair(p)}>
              {p === "all" ? "All pairs" : p}
            </button>
          ))}
        </div>
        <div className="legend">
          <span>
            <i className="sw sw-vanilla" /> Vanilla: kept by arbitrageur
          </span>
          <span>
            <i className="sw sw-auction" /> Auction: bid paid to LPs
          </span>
        </div>
      </div>

      <svg viewBox={`0 0 ${W} ${H + padB}`} className="chart" role="img" aria-label="Vanilla arb vs auction bids">
        {[0.25, 0.5, 0.75, 1].map((f) => (
          <line key={f} x1={padL} x2={W} y1={H - H * f} y2={H - H * f} className="grid" />
        ))}
        {groups.map((g, i) => {
          const x = padL + i * gw + gw / 2;
          const ha = (g.a / max) * (H - 16);
          const hb = (g.b / max) * (H - 16);
          return (
            <g key={g.label}>
              <rect x={x - bw - 2} y={H - ha} width={bw} height={ha} rx={3} className="bar-vanilla">
                <title>{`${g.label} vanilla arb: ${fmt(g.a)}`}</title>
              </rect>
              <rect x={x + 2} y={H - hb} width={bw} height={hb} rx={3} className="bar-auction">
                <title>{`${g.label} bid to LPs: ${fmt(g.b)}`}</title>
              </rect>
              <text x={x} y={H + 16} className="axis" textAnchor="middle">
                {g.label}
              </text>
              <text x={x} y={H + 31} className="axis faint" textAnchor="middle">
                {g.sub}
              </text>
            </g>
          );
        })}
      </svg>

      <div className="chart-foot">
        <div>
          <span className="k">Arb extracted (vanilla)</span>
          <span className="v">{fmt(t.vanillaArb)}</span>
        </div>
        <div>
          <span className="k">Returned to LPs (auction)</span>
          <span className="v accent">{fmt(t.bids)}</span>
        </div>
        <div>
          <span className="k">Recaptured</span>
          <span className="v accent">{fmt(t.recaptured * 100, 1)}%</span>
        </div>
      </div>
      <p className="note">Replay of replay/gaps.json. Placeholder gaps, not market history. Values in each pair's stable.</p>
    </div>
  );
}
