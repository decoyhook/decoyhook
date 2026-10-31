<p align="center">
  <img src="docs/assets/banner.jpg" alt="The DecoyHook mark in holographic foil" width="100%">
</p>

<h1 align="center">DecoyHook</h1>

<p align="center"><b>Decoy your token.</b><br>A bait hook for Uniswap v4 pools on Robinhood Chain.</p>

---

Bots take the bait. The hook takes the bite, and your holders keep it.

DecoyHook is a hook a token team puts on its v4 pools. Snipers, arbitrage bots and liquidity that
jumps in and out around a trade pay a fee sized to the edge they take; people trading normally pay
the pool's normal fee. What the hook collects is split between the pool's liquidity providers, the
token team and holders of $DECOY, by rules fixed when the pool opens.

A decoyed pool is bait, never a trap. The hook never blocks a sell, never charges a transfer tax,
never fills at a price other than the quote, has no owner who can change its fees, and never holds
anyone's tokens. Every decoyed pool has to pass the Decoy Check below.

## Status

| Part | State |
|---|---|
| Decoy Check: a decoy buy and sell through any v4 pool, with a verdict | Live on mainnet |
| Bot Scan: a day of real swaps on a token, routers against bot contracts, and what the hook would have kept | Live on mainnet |
| Decoy Studio: set the bait for a token and replay its last day of bot swaps under those rules | Live on mainnet (deploy of the hook itself: testnet next) |
| Terminal: run checks, scans, hook reads and pool lists from a prompt | Live on mainnet |
| Bait hook: launch guard, gap fee, stay fee, fixed split | Being simulated on real swaps, then testnet |
| $DECOY: fair launch on Robinhood Chain, weekly holder claims | Not launched. The only contract address will be posted on [x.com/decoyhook](https://x.com/decoyhook) |

## The Decoy Check

A v4 hook can run any code inside a swap. Some show one price and settle at another, some block the
sell, and some can be changed by their owner. The check finds out by doing what a trader is about to
do: it runs a small decoy buy and sell through the same pool and hook at the current block, compares
what was quoted with what actually filled, and reads what the hook is allowed to do.

1. **Read.** The pool manager reads a hook's permissions from the lowest 14 bits of its address. The
   check decodes them, marks the four return-delta permissions that let a hook change what a swap
   pays or receives, and looks for a proxy, an upgrade function and an owner.
2. **Quote and buy.** The canonical quoter prices a small buy. A probe contract then buys the same
   amount through the pool and hook.
3. **Sell.** The probe sells everything it received back through the same pool, recording what the
   pool credited, what actually arrived, and the revert reason if a leg fails.
4. **Verdict.** Pass, Caution or Trap, with the round-trip cost and every reason.

The probe never touches the chain. It runs inside `eth_call`, with its code and its input balance
placed by a state override, so a check deploys nothing and spends nothing. It runs twice, once from
the router's address and once from a fresh address, because a hook that treats callers
differently cannot be judged from one run.

## API

| Route | What it returns |
|---|---|
| `POST /v1/check` with `{ "token": "0x…" }`, `{ "poolId": "0x…" }` or `{ "key": { … } }` | A full check report |
| `GET /v1/tokens/:address/pools` | The token's pools against ETH, WETH and USDG, most liquid first |
| `GET /v1/hooks/:address` | A hook's permissions, proxy status and owner |
| `GET /v1/scan/:token` | A day of swaps on the token's most liquid pools: router against contract callers, biggest move, and the gap fee estimate |
| `GET /v1/hot` | The token whose pool saw the most bot-contract swaps in the last half hour |
| `GET /v1/checks/recent` | The latest checks anyone ran, one per pool, newest first |
| `GET /v1/health` | Liveness and the latest block |

Every input is validated against a strict schema. Checks are rate limited and repeated checks of the
same pool within fifteen seconds share one answer.

## Verdict thresholds

| Finding | Caution | Trap |
|---|---|---|
| The sell reverts, including from a transfer tax | | always |
| Round-trip loss | | 50% |
| Fill under the quote | 0.5% | 5% |
| Cost above the pool's own fee | 1% | |
| Transfer fee on the buy | 0.5% | |
| Upgradeable hook, or a pool that answers callers differently | always | |

The thresholds live in [`packages/shared/src/limits.ts`](packages/shared/src/limits.ts); the API and
the site both read them from there.

## What a pass does not mean

- A pass describes one block. An owner can change fees, pause trading or replace upgradeable code later.
- The decoy is small. A large trade moves the price further and can meet limits a small one does not.
- A check reads the pool and the hook. It does not judge the team, the token's supply or its future.

## Run it

Requires Node 24 and, for the contracts, Foundry.

```sh
npm ci
npm test --workspace @decoyhook/shared --workspace @decoyhook/api
cd packages/contracts && forge soldeer install && forge test && cd ../..

# API on :8080, reading the chain through RPC_URL (defaults to the public endpoint)
npm start --workspace @decoyhook/api

# Site on :5173
VITE_API_BASE=http://localhost:8080 npm run dev --workspace @decoyhook/web
```

`node apps/api/scripts/live-check.ts <currency0> <currency1> <fee> <tickSpacing> <hooks>` runs one
check from the command line. After changing the probe, run `forge build` and then
`node apps/api/scripts/sync-probe.ts` to refresh the compiled copy the API uses.

## Repository

```
apps/api            Fastify service: pool lookup, the decoy run, the verdict, HTTP routes
apps/web            The site: home, bot scan, decoy studio, safety check, terminal and token, all in ASCII
packages/shared     Brand, chain addresses, hook permission decoding, verdict thresholds, report type
packages/contracts  The probe contract and its tests (Foundry)
ops/                One Dockerfile per service, and the web server config
```

## Security

- The probe holds no funds and is never deployed; every check is a read-only call.
- No keys are needed to run a check, and none are stored in this repository.
- Report a vulnerability as described in [SECURITY.md](SECURITY.md).

## License

[Apache 2.0](LICENSE)
