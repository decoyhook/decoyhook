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

This repository holds the DecoyHook smart contracts: the hook, the vault and the launchpad, with
their tests and deployment scripts.

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

## Contracts

| Contract | What it does |
|---|---|
| [`DecoyHook`](contracts/src/hook/DecoyHook.sol) | Registers each pool's rules, sets the dynamic fee on every swap and takes the bite above the base fee |
| [`HolderVault`](contracts/src/vault/HolderVault.sol) | Receives the hook's share and pays it out against Merkle roots that wait out a review delay |
| [`DecoyLaunchpad`](contracts/src/launchpad/DecoyLaunchpad.sol) | Launches a token into a decoyed pool in one transaction, with its liquidity locked in the pool |
| [`LaunchToken`](contracts/src/launchpad/LaunchToken.sol) | The fixed-supply token a launch deploys: no owner, no mint after deployment, no tax |

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

`DecoyLaunchpad` launches a token in one transaction: it deploys the token (1,000,000,000 supply),
registers the bait rules, opens a pool against ETH and places the whole supply, minus the creator's
share of at most 5%, as token-only liquidity from the start price up. That position has no withdraw
path; it stays in the pool for good, and a permissionless `collect` sends its fees to the launch's
fee recipient.

## Deployments

| Network | Contract | Address |
|---|---|---|
| Robinhood Chain testnet (46630) | `DecoyHook` | [`0xF413b15685585541fFDeE127f364Ae4cAe2FA0c4`](https://explorer.testnet.chain.robinhood.com/address/0xF413b15685585541fFDeE127f364Ae4cAe2FA0c4) |
| Robinhood Chain testnet (46630) | `HolderVault` | [`0x086364a3f0a8Ec4651B95aC152E9BC37247D9994`](https://explorer.testnet.chain.robinhood.com/address/0x086364a3f0a8Ec4651B95aC152E9BC37247D9994) |
| Robinhood Chain testnet (46630) | `DecoyLaunchpad` | [`0xd0D37d1B965606C30bBf6b0d83BC84263BdA9DFc`](https://explorer.testnet.chain.robinhood.com/address/0xd0D37d1B965606C30bBf6b0d83BC84263BdA9DFc) |

A full loop ran on the testnet, and every step can be opened on the explorer:

| Step | Transaction |
|---|---|
| A trade moves the plain pool and a gap opens | [`0x38e05aa1…0841`](https://explorer.testnet.chain.robinhood.com/tx/0x38e05aa1ba21e29972c87d9c58e1536eb6dc62653334d7dc91278738ff980841) |
| The hook reads the new reference | [`0x9386533f…15b7`](https://explorer.testnet.chain.robinhood.com/tx/0x9386533f777c84331b8d8fe8c332fb3521aabdb5b499d0dc652f663632a215b7) |
| A bot buys in the decoyed pool and pays the bite | [`0x33a4d83e…a573`](https://explorer.testnet.chain.robinhood.com/tx/0x33a4d83e85fa197c186c09a51a19dee9316ff62010770aa6b7e09a63267aa573) |
| The team claims its part | [`0xc1970696…0c66`](https://explorer.testnet.chain.robinhood.com/tx/0xc197069638d6158385515d9ba55a78101eee5fc1abda639c75fac6c2c43c0a66) |
| The hook's share is swept to the vault | [`0xcfd56471…889f`](https://explorer.testnet.chain.robinhood.com/tx/0xcfd564715de25a7e84d1712d9cd517e0813770f622a9450a451fd7af0fa9889f) |
| A token, its rules, its pool and its locked liquidity in one launch | [`0x0d9c3dae…662e`](https://explorer.testnet.chain.robinhood.com/tx/0x0d9c3dae4709ea39ef4d02649db5ff62befccb3c90baf053d4f2a372b1a9662e) |
| A buy inside the launch guard pays the bite | [`0xf084d99c…c233`](https://explorer.testnet.chain.robinhood.com/tx/0xf084d99c65c27663fc6ce6120dfc5fb91377a42bb3de61c0960577525d83c233) |

## Build and test

Requires [Foundry](https://getfoundry.sh).

```sh
cd contracts
forge soldeer install
forge build
forge test
```

The scripts in [`contracts/script`](contracts/script) deploy and exercise the contracts on the
testnet. They read the deployer key from `DEPLOYER_PRIVATE_KEY` in the environment.

## Repository

```
contracts/src/hook        DecoyHook
contracts/src/vault       HolderVault
contracts/src/launchpad   DecoyLaunchpad and LaunchToken
contracts/src/interfaces  The pool manager calls the contracts make
contracts/test            Unit and fuzz tests, run against the real v4 pool manager
contracts/script          Testnet deployment and loop scripts
```

## Security

| Claim | Backed by |
|---|---|
| A pool opens only with registered rules, rules outside the limits are refused, and rules never change once open | [`DecoyHook.t.sol`](contracts/test/DecoyHook.t.sol) |
| The fee charged stays within the pool's limits for any swap | [`DecoyHook.t.sol`](contracts/test/DecoyHook.t.sol) (fuzzed) |
| A swap never uses a reference read in its own block | [`DecoyHook.t.sol`](contracts/test/DecoyHook.t.sol) |
| Sells go through during the launch guard, and a buy followed by a full sell never reverts | [`DecoyHook.t.sol`](contracts/test/DecoyHook.t.sol), [`DecoyLaunchpad.t.sol`](contracts/test/DecoyLaunchpad.t.sol) (fuzzed) |
| A launch's liquidity stays in the pool after fees are collected, and the fees go to its fee recipient | [`DecoyLaunchpad.t.sol`](contracts/test/DecoyLaunchpad.t.sol) |
| A vault root waits out its delay, cannot promise more than the vault holds, and each claim pays once | [`HolderVault.t.sol`](contracts/test/HolderVault.t.sol), [`MerkleVector.t.sol`](contracts/test/MerkleVector.t.sol) |

Every commit on `main` is signed, and the actions are pinned by commit. Known limitations:

- A launch has no reference pool, so its pool charges the base fee and the launch guard only.
- The bite is taken on the side a swap does not specify, so an exact-input buy pays it in the token
  bought.
- A gap that opens and closes within the same block is not charged, because a swap only sees a
  reference from an earlier block.
- The vault's poster and guardian can delay or veto a root. Neither can move funds.

Report a vulnerability as described in [SECURITY.md](SECURITY.md).

## Official links

[decoyhook.com](https://decoyhook.com) and [x.com/decoyhook](https://x.com/decoyhook) are the only
official channels. A token, contract address or account presented as DecoyHook's is ours only if it
is listed there. Questions and integrations go to [x.com/decoyhook](https://x.com/decoyhook), and
security reports follow [SECURITY.md](SECURITY.md).

## License

[Apache-2.0](LICENSE)
