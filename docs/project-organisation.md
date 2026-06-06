# MicroHttp Project Organisation Design

## MicroHttp Project Layout Decision

Use a conventional Haskell layout, adapted for MicroHs:

```text
micro-http/
  micro-http.cabal
  Makefile
  docs/
  src/
    MicroHttp.hs
    MicroHttp/
      ...
  test/
    unit/
      MicroHttp/
        ...
    integration/
      MicroHttp/
        ...
  app/
    Main.hs
  spike/
    MicroHttp/
      Spike*.hs
```

## MicroHttp Haskell Layout Conventions

Common Haskell package conventions are:

- `src/` for library modules.
- `app/` for executable entry points.
- `test/` or `tests/` for test suites.
- `bench/` for benchmarks when needed.
- One `.cabal` file at the package root.
- Module names mirror file paths.

This project should follow those conventions even if the first build automation
uses `Makefile` and `mhs` directly. That keeps the tree familiar to Haskell
readers and leaves room for `mcabal` integration.

## MicroHttp Spike Code Policy

Keep `spike/` as evidence and exploratory code. Do not import from `spike/` in
production modules.

When a spike result becomes production code, copy or rewrite it into `src/` with
tests under `test/`. Do not gradually mutate spike modules into production
modules.

## MicroHttp Test Layout Decision

Use `test/unit/...` for unit specs and `test/integration/...` for specs that
touch the filesystem, sockets, subprocesses, environment, clock, or other
external effects. Within each suite, mirror `src/MicroHttp/...` module paths.

Suggested test split:

```text
test/
  unit/
    Main.hs
    MicroHttp/
      HtmlSpec.hs
      Http/
        ParserSpec.hs
        ResponseSpec.hs
      RouterSpec.hs
      ServerSpec.hs
  integration/
    Main.hs
    MicroHttp/
      Http/
        ResponseFileSpec.hs
      Network/
        SocketSpec.hs
```

Pure unit tests should not open sockets or touch the filesystem. Filesystem and
network checks should be named as integration tests and run through separate
targets.

## MicroHttp Test Harness Decision

Use `nanospec`, which provides a small `Test.Hspec` subset, for the current test
harness. Each spec module should export `spec :: Spec`; suite drivers should
import those modules and call `hspec`.

Avoid `hspec-discover` for now. It depends on preprocessor/build-tool behaviour
that is not needed while the MicroHs build remains Makefile-driven.
