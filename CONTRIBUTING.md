# Contributing

Thanks for taking the time to improve DecoyHook. This guide covers the setup, the checks every change
must pass and how to send it.

Found a vulnerability? Do not open an issue or pull request. Follow [SECURITY.md](SECURITY.md)
instead.

## Setup

Install [Foundry](https://getfoundry.sh), then:

```sh
git clone https://github.com/decoyhook/decoyhook.git
cd decoyhook/contracts
forge soldeer install
```

## Checks

Every pull request must pass these. CI runs the same commands.

```sh
forge build --sizes
forge test
```

## Commits

- Conventional prefixes: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `chore`, `build`,
  `style`, `ci`, `revert`, with a scope where it helps, for example `fix(hook):`.
- The subject is imperative, lowercase after the colon, under 72 characters and without a trailing
  period. The body explains why.
- One logical change per commit.
- Commits to `main` are signed.

## Pull requests

Fill in the template: what changes and why, how it was tested, and its security impact. A change to
what a swap pays, how the bite is split, what a pool's rules allow after it opens, what the launchpad
locks or how the vault pays out needs a test that shows the new behavior.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
