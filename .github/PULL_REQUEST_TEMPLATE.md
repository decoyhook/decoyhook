## Summary

<!-- What changes, and why. Link the issue it closes, for example "Closes #12". -->

## How it was tested

<!-- Commands run, new tests added, and anything checked by hand. -->

## Checks

- [ ] `npm run typecheck` passes
- [ ] `npm test --workspace @decoyhook/shared --workspace @decoyhook/api` passes
- [ ] `npm run build --workspace @decoyhook/web` passes
- [ ] `forge build` and `forge test` pass in `packages/contracts` (contract changes only)
- [ ] New behavior has tests, and a fix has a test that fails without it

## Security impact

<!--
Does this change what a swap pays, how the bite is split, what a pool's rules allow after it opens,
what the launchpad locks, how the vault pays out, or what the site asks a wallet to sign?
Describe the effect, or write "None".
-->

- [ ] No secrets, private keys or `.env` files are included

## Docs

- [ ] The README, `SECURITY.md` and the site docs are updated, or no update is needed
