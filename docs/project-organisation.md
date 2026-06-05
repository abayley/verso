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

Use `test/MicroHttp/...` for test modules that mirror `src/MicroHttp/...`.

Suggested test split:

```text
test/
  MicroHttp/
    HtmlTest.hs
    Http/
      ParserTest.hs
      ResponseTest.hs
    RouterTest.hs
    Router/
      TypedTest.hs
    Store/
      FileSystemTest.hs
    ServerIntegrationTest.hs
```

Pure unit tests should not open sockets or touch the filesystem. Filesystem and
network checks should be named as integration tests and run through separate
targets.

## MicroHttp Test Harness Decision

Start with a small local assertion harness if package availability is uncertain.
Move to `HUnit` or `hspec` only after confirming the active MicroHs package DB
has the required packages installed.

The MicroHs package list says `HUnit`, `hspec`, and related packages are known
to compile, but they were not verified as installed in this workspace during the
spike run.
