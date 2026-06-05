# MicroHttp Build Automation Design

## MicroHttp Build Automation Goals

Build automation should make the common checks boring:

- Compile the library.
- Run pure unit tests.
- Run integration tests.
- Run spike builds when requested.
- Lint Markdown docs.
- Clean generated binaries.

## MicroHttp Initial Make Targets

Use `Makefile` first because the local workflow already has a checked-out
MicroHs compiler at `../MicroHs/bin/mhs`.

Recommended targets:

```makefile
build
test
test-integration
spikes
docs
check
clean
```

The current spike targets should remain while design is being reviewed, but the
main `check` target should eventually run production build and tests, not every
spike by default.

## MicroHttp Cabal Or MicroCabal Direction

Add `micro-http.cabal` once the first production modules exist in `src/`.

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
make -C micro-http test
```

Use full checks before review:

```sh
make -C micro-http check
```

Integration tests that bind ports should not run implicitly in every tiny unit
test loop unless they are fast and deterministic.
