# Security policy

## Reporting a vulnerability

Email **admin@decoyhook.com** with the subject "security". Once this repository is public, GitHub's
private vulnerability reporting works too. Do not open a public issue for a security problem.

Include what you found, how to reproduce it and what an attacker could do with it. You will get an
acknowledgement within three days and a status update within ten.

Nobody from the team will ever ask you for a seed phrase, a private key or a payment.

## In scope

- The bait hook (`packages/contracts/src/hook`): anything that lets a swap pay more than its quote
  showed, blocks a sell, moves funds it should not, or lets anyone change a pool's rules after it
  opens.
- The holder vault (`packages/contracts/src/vault`): anything that pays out more than a root
  commits, pays the wrong account, or unlocks the supply stream faster than its schedule.
- The probe contract (`packages/contracts/src/probe`) and the check pipeline in `apps/api`: anything
  that makes a trap read as a pass, or a pass read as a trap.
- Input handling in the API: validation, rate limits and resource use.
- The site in `apps/web`.

The hook and the vault run on the testnet only. Their addresses are listed on the site's claim page.

## Known limits

These are properties of the design, not vulnerabilities. The site's docs publish them under "limits
and trust".

- A check describes one block with a small decoy. A pool can change afterwards, and size-dependent
  behaviour can be missed.
- A hook could detect a simulation in ways the two caller addresses do not cover.
- The gap fee reads its reference from an earlier block. A thin or stale reference makes the fee less
  precise; with no usable reference the pool charges its base fee.
- The vault's poster and guardian can delay or veto a weekly root. Neither can move funds.
