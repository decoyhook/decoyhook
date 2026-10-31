# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting on this
repository. Do not open a public issue for a security problem.

Include what you found, how to reproduce it and what an attacker could do with it. You will get an
acknowledgement within three days and a status update within ten.

## In scope

- The probe contract in `packages/contracts`.
- The verdict engine and the check pipeline in `apps/api`: anything that makes a trap read as a pass,
  or a pass read as a trap.
- Input handling in the API: validation, rate limits and resource use.
- The site in `apps/web`.

## Known limits

These are properties of the method, not vulnerabilities. They are published on the site's method page.

- A verdict describes one block. A hook owner can change behaviour afterwards.
- The decoy is small, so size-dependent limits may not trigger.
- A hook could detect a simulation in ways the two caller addresses do not cover.
