# MicroHttp Project Organisation Design

## MicroHttp Project Layout Decision

Use a conventional Haskell layout, adapted for MicroHs. The web framework lives
under the `MicroHttp` namespace and the Verso wiki application under `Verso`
(RFC-0030); `Verso.*` depends on `MicroHttp.*`, never the reverse. The
application's TypeScript editor source lives under `src/Verso/Editor/`:

```text
micro-http/
  micro-http.cabal
  Makefile
  docs/
  src/
    MicroHttp.hs            framework facade
    MicroHttp/              framework modules
      ...
    Verso/                  the wiki application
      App.hs               routed application assembly
      Main.hs              server executable (module Main)
      ReplayTool.hs        operation-log replay executable (module Main)
      Config.hs            application config (VERSO_ keys)
      ...
      Editor/              TypeScript editor source
        ...
  static/
    editor/
      ...
  test/
    unit/
      MicroHttp/           framework specs
        ...
      Verso/               application specs
        ...
    integration/
      MicroHttp/
        ...
      Verso/
        ...
  spike/
    MicroHttp/
      Spike*.hs
```

## MicroHttp Source Layout Conventions

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

The Markdown editor follows the same source-vs-asset distinction:

- `src/Verso/Editor/` contains TypeScript source for the application's web
  components.
- `static/editor/` contains files the application serves directly, including the
  generated JavaScript bundle and CSS.
- `test/editor/` contains TypeScript tests for editor source modules.

Do not put TypeScript source under `static/`; that directory is for served
assets.

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
