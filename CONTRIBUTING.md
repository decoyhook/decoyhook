# Contributing

Thanks for taking the time to improve DecoyHook. This guide covers the setup, the checks every change
must pass and how to send it.

Found a vulnerability? Do not open an issue or pull request. Follow [SECURITY.md](SECURITY.md)
instead.

## Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Node.js | 24, as pinned in [`.nvmrc`](.nvmrc) | Every TypeScript workspace. The API and the shared package run from source |
| npm | The version bundled with Node.js 24 | Installing the workspaces from `package-lock.json` |
| Foundry | A current stable release | Building and testing `packages/contracts` |

## Layout

| Workspace | Package | What it is |
|---|---|---|
| `apps/web` | `@decoyhook/web` | The site: home, launch, studio, claim, terminal, token and docs |
| `apps/api` | `@decoyhook/api` | The public API: checks, scans, launch plans and the holder check |
| `packages/shared` | `@decoyhook/shared` | Brand, chain addresses, permission decoding and the limits both apps read |
| `packages/contracts` | `@decoyhook/contracts` | The hook, the vault, the launchpad and the probe, built with Foundry |

## Setup

```sh
git clone https://github.com/decoyhook/decoyhook.git
cd decoyhook
npm ci
cd packages/contracts && forge soldeer install
```

## Checks

Every pull request must pass these. CI runs the same commands.

```sh
npm run typecheck
npm test --workspace @decoyhook/shared --workspace @decoyhook/api
npm run build --workspace @decoyhook/web

cd packages/contracts
forge build --sizes
forge test
```

A change to the probe needs `forge build` and then `node apps/api/scripts/sync-probe.ts`, so the API
runs the same bytecode the tests ran.

## Commits

- Conventional prefixes: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `chore`, `build`,
  `style`, `ci`, `revert`, with a scope where it helps, for example `fix(api):`.
- The subject is imperative, lowercase after the colon, under 72 characters and without a trailing
  period. The body explains why.
- One logical change per commit. Contracts, API and site changes go in separate commits.
- Commits to `main` are signed.

## Pull requests

Fill in the template: what changes and why, how it was tested, and its security impact. A change to
what a swap pays, how the bite is split, what a pool's rules allow after it opens, what the launchpad
locks or what the site asks a wallet to sign needs a test that shows the new behavior.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
