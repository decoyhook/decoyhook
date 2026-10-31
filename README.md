<p align="center">
  <img src="docs/assets/banner.jpg" alt="The DecoyHook mark in holographic foil" width="100%">
</p>

<h1 align="center">DecoyHook</h1>

<p align="center"><b>Send the decoy first.</b><br>A safety layer for Uniswap v4 hooks on Robinhood Chain.</p>

---

A v4 hook can run any code inside a swap. Some show one price and settle at another, some block the
sell, and some can be changed by their owner. DecoyHook finds out before you trade: it runs a small
decoy buy and sell through the same pool and hook at the current block, compares what was quoted
with what actually filled, and reads what the hook is allowed to do.

## How a check works

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

## Status

| Part | State |
|---|---|
| Decoy Check: probe, verdict engine, API, site | Live on mainnet; the public domain follows |
| Guarded swap: a router that reverts if its own decoy sell fails | In development |
| Holder Vault: weekly claims by time-weighted balance | Designed |

## API

| Route | What it returns |
|---|---|
| `POST /v1/check` with `{ "token": "0x…" }`, `{ "poolId": "0x…" }` or `{ "key": { … } }` | A full check report |
| `GET /v1/tokens/:address/pools` | The token's pools against ETH, WETH and USDG, most liquid first |
| `GET /v1/hooks/:address` | A hook's permissions, proxy status and owner |
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
apps/web            The site: home with a live decoy run, the check page, the method
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
