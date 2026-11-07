# Reopen Auction Hook

**A Uniswap v4 hook that auctions the first swap after a market reopen and pays the winning bid to LPs.**

Tokenized stocks trade on-chain 24/7, but their real market closes every night and weekend. When it reopens, the
underlying price jumps and the pool still sits at the stale close price. Whoever swaps first takes the whole gap
from LPs. That is pure loss-versus-rebalancing (LVR), and it happens on every pool at every open.

This hook turns that race into a sale:

1. **Lock.** At reopen, the keeper calls `startAuction(key, refPrice)`. Public swaps and liquidity adds revert.
2. **Dutch auction.** The price starts at 1.5x an on-chain estimate of the arb profit and falls to 0 block by block.
3. **Win.** The first `bidAndSwap` pays the current price, swaps the pool to the reference price, and donates the
   bid to in-range LPs, all in one transaction.
4. **Reopen.** The pool is open again. If nobody bids, it reopens on its own when the auction ends.

One hook serves any number of pools. All state is keyed by `PoolId`.

```
Keeper ──startAuction(key, ref)──▶ ReopenAuctionHook ◀──bidAndSwap(key, params, maxBid)── Bidder
                                        │  locks pool, Dutch price falls per block
                                        ▼
                         PoolManager.unlock → swap → donate(bid) → settle with bidder
                                        │  events: AuctionStarted, AuctionWon
                                        ▼
                                LPs collect the bid as fees
```

## Result

`forge test --match-contract ReplayTest -vv` replays close→open gaps through a vanilla pool and an auction pool built
on the same tokens:

```
events: 40 | profitable gaps: 39
VANILLA  arbs extract 9459.59 | LPs get 1751.75
AUCTION  winners keep 920.77  | LPs get 10290.57 (bids 8538.82)
RECAPTURED for LPs: 90.26% of reopen arbitrage
```

> The gaps in `replay/gaps.json` are **illustrative placeholder data**, not market history. Swap in real
> close/open prints to get real numbers. No code changes are needed. Per-event output goes to `replay/results.csv`.

LPs don't get the remaining ~10% because of the price steps: with 10 blocks, each block drops the price by 15% of
the start, and the winner keeps up to one step. Longer auctions or a smaller premium (`setConfig`) raise recapture.

## How it works

| Piece | Where |
|---|---|
| Lock: `beforeSwap` and `beforeAddLiquidity` revert while an auction is live | `_beforeSwap`, `_beforeAddLiquidity` |
| Start price: `L·(√P_ref − √P_pool)² / √P_pool` × `startPremiumBps` (exact for full-range liquidity) | `estimateArbProfit` |
| Dutch price: `startBid · (endBlock − block) / auctionBlocks` | `currentPrice` |
| Winner's swap: the hook is `msg.sender` to the PoolManager, so v4 skips the hook's own `beforeSwap` | `unlockCallback` |
| Payout: `donate(bid)` after the swap, so LPs in range at the new price get it | `unlockCallback` |
| Bid currency: currency1 by default, `setBidCurrency(key, true)` for currency0 | `bidInCurrency0` |

## Layout

```
src/ReopenAuctionHook.sol          the hook (auction lives inside it)
test/ReopenAuctionHook.t.sol       scenes 1-4 + 5-pool test (mixed decimals, fee tiers, gap directions)
test/Replay.t.sol                  scene 5: vanilla vs auction replay -> replay/results.csv
test/utils/AuctionFixture.sol      generic multi-pair fixture (currency0/currency1, any decimals)
script/Deploy.s.sol                mine + deploy hook, mock pairs, pools, liquidity -> deployments/<chainId>.json
script/StartAuction.s.sol          keeper: lock a pool at reopen
script/Bid.s.sol                   bidder: win the auction and arb
script/Status.s.sol                phase / Dutch price / pool price for every pool
keeper/index.ts                    TS keeper: waits for market open, starts auctions, logs events
replay/gaps.json                   pair config + close/open gaps (used by the replay and by Deploy)
```

## Run it

```bash
forge test                                   # 22 tests
forge test --match-contract ReplayTest -vv   # the comparison table
```

End-to-end on anvil:

```bash
anvil
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil account 0
export RPC=http://localhost:8545

forge script script/Deploy.s.sol --rpc-url $RPC --broadcast                               # hook + 5 pools
POOL=0 PRICE_E6=186500000 forge script script/StartAuction.s.sol --rpc-url $RPC --broadcast # reopen at 186.5
forge script script/Status.s.sol --rpc-url $RPC                                           # watch the price fall
POOL=0 BIDDER_KEY=<another key> forge script script/Bid.s.sol --rpc-url $RPC --broadcast   # win, arb, pay LPs
```

Keeper bot (TypeScript, viem). It waits for the next weekday 09:30 America/New_York, reads reference prices, starts
every pool's auction and logs `AuctionStarted` / `AuctionWon`:

```bash
cd keeper && npm install
PRIVATE_KEY=... RPC_URL=$RPC npx tsx index.ts --now   # --now skips the schedule (demo)
```

Reference prices come from `keeper/prices.json` (`{"<poolIndex>": price}`). Swap `fetchRefPrices` for a real feed or a
Chainlink CRE workflow. `OPEN_TIME` / `OPEN_TZ` change the schedule.

On a testnet with Uniswap v4, use the same commands with your RPC. `Deploy` uses hookmate's canonical v4 addresses
for that chain. `PRICE_E6` is currency1 per currency0 in whole tokens, scaled by 1e6. Env options are documented at
the top of each script.

## Threat model

| Risk | Mitigation / status |
|---|---|
| **JIT liquidity**: add liquidity right before the win, take part of the donation, remove it | Liquidity adds revert while the auction is live. The swap and the donation happen atomically. |
| **Keeper front-run**: an arb swaps at the stale price before `startAuction` lands | **Open.** The keeper must lock at or before the reopen. Better: lock at market close and only set the reference price at reopen, or start via Chainlink CRE. |
| **Wrong reference price**: the keeper is trusted for `refPrice` | It only sets the start price. The winner chooses its own swap, and a too-high start just decays. A malicious keeper can lock a pool for at most `auctionBlocks`. The owner can `cancelAuction`. |
| **Estimate too low** (concentrated liquidity crossing ticks) | The 1.5x premium absorbs part of it. A too-low start leaves value to the winner but never harms LPs compared with vanilla. |
| **Bidder overpays / gets sandwiched** | The `maxBid` guard. The swap uses `sqrtPriceLimitX96` for the price limit. Nobody else can swap while the auction is live. |
| **Block builder censors other bidders** | Inherent to block-based Dutch auctions. A short auction caps it. |
| **Stuck pool** | It auto-reopens after `endBlock`, and the owner can `cancelAuction`. |
| **Native ETH pools** | Not supported (`NativeCurrencyUnsupported`). |
| **Owner/keeper keys** | Single EOA for the hackathon. Use a multisig and a CRE workflow in production. |

## Limitations / next

- The keeper (`keeper/index.ts`) uses a fixed schedule and a JSON price file. A Chainlink CRE workflow with a live price feed is the next step.
- The replay data is a placeholder. The comparison against alternative designs has a free column in the replay.
- No frontend yet. `replay/results.csv` and the `AuctionStarted` / `AuctionWon` events are what it would read.
- Solidity 0.8.30, Uniswap v4 via OpenZeppelin `uniswap-hooks` 1.1.0. The code is unaudited.
