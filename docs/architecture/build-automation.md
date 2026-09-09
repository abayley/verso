# MicroHttp Build Automation Design

## MicroHttp Build Automation Goals

Build automation should make the common checks boring:

- Run Haskell format checks.
- Run Haskell lint checks.
- Run pure unit tests.
- Run integration tests.
- Run spike builds when requested.
- Lint Markdown docs.
- Clean generated binaries.

## MicroHttp Initial Make Targets

Use `Makefile` first because the local workflow is still direct MicroHs
compilation rather than Cabal-managed package builds. The Makefile expects
`mhs`, `fourmolu`, `hlint`, and `markdownlint-cli2` to be visible on `PATH`.

Recommended targets:

```makefile
format
format-check
lint
test-unit
test
test-integration
all-spikes
docs
check
clean
```

The spike targets remain available for historical reproducibility, but the main
`check` target runs the production quality gate, not every spike by default.

## MicroHttp Cabal Or MicroCabal Direction

The framework is a MicroCabal package at `packages/micro-http/` with its own
`micro-http.cabal` (RFC-0038); the application resolves it from the package
database. This section records the original direction.

The Cabal file should describe:

- Library modules under `src`.
- Test executable modules under `test`.
- Optional example executable under `app`.

The Makefile can call `mcabal` later, but direct `mhs` commands are acceptable
until the module list stabilises.

## MicroHttp Continuous Check Strategy

Use fast checks for iteration:

```sh
make -C micro-http docs
make -C micro-http format-check
make -C micro-http lint
make -C micro-http test-unit
```

Run effectful checks separately when touching filesystem, socket, or server
lifecycle code:

```sh
make -C micro-http test-integration
```

Use full checks before review:

```sh
make -C micro-http check
```

Integration tests that bind ports should not run implicitly in every tiny unit
test loop unless they are fast and deterministic.
