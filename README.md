<div align="center">

<a href="https://decoyhook.com"><img src="docs/assets/banner.jpg" alt="The DecoyHook mark, a D drawn as a hook, in holographic foil" width="100%"></a>

# DecoyHook

**Decoy your token.**

A bait hook for Uniswap v4 pools on Robinhood Chain. Bots pay for the edge they take.<br>
Normal trades pay the normal fee. Never a honeypot.

<a href="https://github.com/decoyhook/decoyhook/actions/workflows/ci.yml"><img src="https://github.com/decoyhook/decoyhook/actions/workflows/ci.yml/badge.svg" alt="CI status" height="20"></a>
<a href="https://github.com/decoyhook/decoyhook/actions/workflows/codeql.yml"><img src="https://github.com/decoyhook/decoyhook/actions/workflows/codeql.yml/badge.svg" alt="CodeQL status" height="20"></a>
<a href="https://scorecard.dev/viewer/?uri=github.com/decoyhook/decoyhook"><img src="https://api.scorecard.dev/projects/github.com/decoyhook/decoyhook/badge" alt="OpenSSF Scorecard" height="20"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-2ee6c8" alt="License: Apache-2.0" height="20"></a>

[Website](https://decoyhook.com) · [Docs](https://decoyhook.com/docs) · [Decoy Studio](https://decoyhook.com/studio) · [Launch a token](https://decoyhook.com/launch) · [Security policy](SECURITY.md) · [X](https://x.com/decoyhook)

</div>

<br>

## What it does

A Uniswap v4 hook runs inside every swap of the pools that use it. DecoyHook uses that position to
price what bots take from a pool:

- **Arbitrage** that closes a price gap against a reference pool pays a fee sized to that gap.
- **Snipers** buying in the first minutes of a new pool pay a launch fee that fades to the base fee.
- **Everyone else** pays the pool's base fee and nothing more.

What a pool collects above its base fee is the bite. Part of it stays in the pool as fees for
liquidity providers, part goes to the token team, and a fixed part is the hook's share. Every rate
and every share is fixed when the pool opens, the dynamic fee is visible to any quoter before a swap,
and no one can change a pool's rules afterwards.

A decoyed pool is bait, never a trap. The hook never blocks a sell, never charges a transfer tax,
never fills at a price other than the quote, has no owner, and never holds anyone's tokens.

## How it works

### The gap fee

Each decoyed pool names a reference pool for the same pair. The hook snapshots the reference price
after every swap and through a permissionless `poke()`, and a swap only ever uses a snapshot taken
in an earlier block, so no one can move the reference and trade against it in the same transaction.
A snapshot older than 600 blocks is not used.

When a swap moves the pool toward the reference price, the hook charges

```
fee = base + (gap - deadBand) * capture
```

capped at the pool's `cap`. A swap that moves the price away from the reference, or a gap inside the
dead band, pays the base fee.

### The launch guard

For a set time after a pool opens, buys pay a fee that starts at `guardStart` and falls in a straight
line to the base fee. Sells are never charged the guard. The guard is at most 50% and lasts at most
600 seconds, limits the contract enforces.

### The split

The hook overrides the pool's dynamic LP fee with the largest of the base fee, the gap fee and the
guard fee. The bite above the base fee is divided by shares set at registration: the LP part is
added to the LP fee, and the rest is taken by the hook through `afterSwapReturnDelta` and divided
between the token team and the vault.

### Fixed at birth

A pool's rules are registered by the same address that initializes the pool, and the hook checks
them in `beforeInitialize`. The contract has no owner, no upgrade path and no function that changes
a pool's rules once it is open. Its four permissions (`beforeInitialize`, `beforeSwap`, `afterSwap`,
`afterSwapReturnDelta`) are encoded in its address, flags `0x20C4`.

### Launching a token

The launch window offers two venues. A **direct launch** goes through `DecoyLaunchpad` in one
transaction: it deploys the token (1,000,000,000 supply, no owner, no tax), registers the bait rules,
opens a pool against ETH and places the whole supply, minus the creator's share of at most 5%, as
token-only liquidity from the start price up. That position has no withdraw path; it stays in the
pool for good, and a permissionless `collect` sends its fees to the launch's fee recipient. A
**curve launch** goes through the chain's bonding-curve launchpad, and its graduation pool can get a
decoyed pool beside it from the studio. Every launch is simulated from the creator's address before
the wallet is asked to sign.

### The Decoy Check

A v4 hook can run any code inside a swap. The check finds out what a pool does by doing what a
trader is about to do, at the current block:

1. **Read.** It decodes the hook's permissions from the lowest 14 bits of its address, marks the
   return-delta permissions that let a hook change what a swap pays or receives, and looks for a
   proxy, an upgrade function and an owner.
2. **Quote and buy.** The canonical quoter prices a small buy. A probe contract then buys the same
   amount through the pool and hook.
3. **Sell.** The probe sells everything back through the same pool, recording what the pool
   credited, what arrived, and the revert reason if a leg fails.
4. **Verdict.** Pass, Caution or Trap, with the round-trip cost and every reason.

The probe is never deployed. It runs inside `eth_call` with its code and balance placed by a state
override, so a check spends nothing. It runs twice, from the router's address and from a fresh one,
because a hook that treats callers differently cannot be judged from one run. Tokens with an
issuer's pause or blocklist are read too, and reported as a caution with the reason.

| Finding | Caution | Trap |
|---|---|---|
| The sell reverts, including from a transfer tax | | always |
| Round-trip loss | | 50% |
| Fill under the quote | 0.5% | 5% |
| Cost above the pool's own fee | 1% | |
| Transfer fee on the buy | 0.5% | |
| Upgradeable hook, or a pool that answers callers differently | always | |

The thresholds live in [`packages/shared/src/limits.ts`](packages/shared/src/limits.ts), and the API
and the site both read them from there.

## Deployments

| Network | What | Address |
|---|---|---|
| Robinhood Chain (4663) | Decoy Check, Decoy Studio, Bot Scan, terminal and curve launches | [decoyhook.com](https://decoyhook.com), [api.decoyhook.com](https://api.decoyhook.com/v1/health) |
| Robinhood Chain testnet (46630) | `DecoyHook` | [`0xF413b15685585541fFDeE127f364Ae4cAe2FA0c4`](https://explorer.testnet.chain.robinhood.com/address/0xF413b15685585541fFDeE127f364Ae4cAe2FA0c4) |
| Robinhood Chain testnet (46630) | `HolderVault` | [`0x086364a3f0a8Ec4651B95aC152E9BC37247D9994`](https://explorer.testnet.chain.robinhood.com/address/0x086364a3f0a8Ec4651B95aC152E9BC37247D9994) |
| Robinhood Chain testnet (46630) | `DecoyLaunchpad` | [`0xd0D37d1B965606C30bBf6b0d83BC84263BdA9DFc`](https://explorer.testnet.chain.robinhood.com/address/0xd0D37d1B965606C30bBf6b0d83BC84263BdA9DFc) |

A full loop ran on the testnet: a gap opened on a plain pool, a bot buy in the decoyed pool paid the
bite, the team claimed its part and the vault received its share. Every step is linked from
[`packages/shared/src/testnet.ts`](packages/shared/src/testnet.ts).

## API

Public, read-only and keyless, at `https://api.decoyhook.com`.

| Route | What it returns |
|---|---|
| `POST /v1/check` | A full Decoy Check report for `{ "token" }`, `{ "poolId" }` or `{ "key" }` |
| `GET /v1/tokens/:address/pools` | The token's pools against ETH, WETH and USDG, most liquid first |
| `GET /v1/hooks/:address` | A hook's permissions, proxy status and owner |
| `GET /v1/scan/:address` | A day of swaps on the token's busiest pools: routers against contract callers, the biggest moves and the gap fee estimate |
| `GET /v1/hot` | The token whose pool saw the most bot-contract swaps in the last half hour |
| `GET /v1/stats` | Swaps and bot swaps across the chain's v4 pools in the last half hour |
| `GET /v1/checks/recent` | The latest checks anyone ran, one per pool |
| `GET /v1/graduates` | Tokens that recently graduated from the bonding-curve launchpad, with their pools |
| `POST /v1/launch/plan` | A ready-to-sign launch transaction, simulated from the creator |
| `GET /v1/launches` | Recent direct launches |
| `GET /v1/holders`, `GET /v1/holders/:address` | The vault's holder check, and an account's proof and claim call |
| `GET /v1/owed/:address` | What a team address can withdraw from the hook |
| `GET /v1/health` | Liveness and the latest block |

Every input is validated against a strict schema, checks are rate limited, and repeated checks of
the same pool within fifteen seconds share one answer.

## Architecture

```
            browser
               |
     decoyhook.com (apps/web) ---- wallet signs launches, claims, pool plans
               |
   api.decoyhook.com (apps/api)
      |            |            |
  eth_call     log reads     holder ledger
  + state      (swaps,       (transfers, vault
  override     graduations)   roots, proofs)
      |            |            |
      +------- Robinhood Chain RPC -------+
                     |
     pool manager <-> DecoyHook <-> HolderVault
                     ^
               DecoyLaunchpad
```

The site and the API hold no keys. Every number the site shows comes from the chain through the API,
and the method behind each one is published in the docs.

## Repository

```
apps/api            Fastify service: pool lookup, the decoy run, scans, launch plans, the holder check
apps/web            The site: home, launch, studio, claim, terminal, token and docs
packages/shared     Brand, chain addresses, permission decoding, verdict thresholds, launch terms
packages/contracts  DecoyHook, HolderVault, DecoyLaunchpad, the probe and their tests (Foundry)
ops/                One Dockerfile per service, and the web server config
docs/               Repository assets
```

## Run it

Requires Node.js 24 (see [`.nvmrc`](.nvmrc)) and, for the contracts, Foundry.

```sh
npm ci
npm run typecheck
npm test --workspace @decoyhook/shared --workspace @decoyhook/api

cd packages/contracts && forge soldeer install && forge test && cd ../..

# API on :8080, reading the chain through RPC_URL
npm start --workspace @decoyhook/api

# Site on :5173
VITE_API_BASE=http://localhost:8080 npm run dev --workspace @decoyhook/web
```

`node apps/api/scripts/live-check.ts <currency0> <currency1> <fee> <tickSpacing> <hooks>` runs one
check from the command line. After changing the probe, run `forge build` and then
`node apps/api/scripts/sync-probe.ts` to refresh the compiled copy the API uses.

## Security

| Claim | Backed by |
|---|---|
| A pool opens only with registered rules, rules outside the limits are refused, and rules never change once open | [`DecoyHook.t.sol`](packages/contracts/test/DecoyHook.t.sol) |
| The fee charged stays within the pool's limits for any swap | [`DecoyHook.t.sol`](packages/contracts/test/DecoyHook.t.sol) (fuzzed) |
| A swap never uses a reference read in its own block | [`DecoyHook.t.sol`](packages/contracts/test/DecoyHook.t.sol) |
| Sells go through during the launch guard, and a buy followed by a full sell never reverts | [`DecoyHook.t.sol`](packages/contracts/test/DecoyHook.t.sol), [`DecoyLaunchpad.t.sol`](packages/contracts/test/DecoyLaunchpad.t.sol) (fuzzed) |
| A launch's liquidity stays in the pool after fees are collected, and the fees go to its fee recipient | [`DecoyLaunchpad.t.sol`](packages/contracts/test/DecoyLaunchpad.t.sol) |
| A vault root waits out its delay, cannot promise more than the vault holds, and each claim pays once | [`HolderVault.t.sol`](packages/contracts/test/HolderVault.t.sol), [`MerkleVector.t.sol`](packages/contracts/test/MerkleVector.t.sol) |
| The probe reports a blocked sell, a sell tax and a buy fee from what actually settled | [`DecoyProbe.t.sol`](packages/contracts/test/DecoyProbe.t.sol) (fuzzed) |

Every commit on `main` is signed, the actions are pinned by commit, the base images by digest and
the packages by exact version. Known limitations:

- A direct launch has no reference pool, so its pool charges the base fee and the launch guard only.
- The bite is taken on the side a swap does not specify, so an exact-input buy pays it in the token
  bought.
- A gap that opens and closes within the same block is not charged, because a swap only sees a
  reference from an earlier block.
- A Decoy Check describes one block and a small trade. A hook with an owner or an upgrade path can
  behave differently later, and a large trade can meet limits a small one does not.

Report a vulnerability as described in [SECURITY.md](SECURITY.md).

## Official links

[decoyhook.com](https://decoyhook.com) and [x.com/decoyhook](https://x.com/decoyhook) are the only
official channels. A token, contract address or account presented as DecoyHook's is ours only if it
is listed there. Questions and integrations: admin@decoyhook.com.

## License

[Apache-2.0](LICENSE)
