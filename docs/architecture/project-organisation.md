# MicroHttp Project Organisation Design

## MicroHttp Project Layout Decision

Use a conventional Haskell layout, adapted for MicroHs. The web framework lives
under the `MicroHttp` namespace and the Verso wiki application under `Verso`
(RFC-0030); `Verso.*` depends on `MicroHttp.*`, never the reverse. Since RFC-0038
the code is split into packages under `packages/`: the framework is its own
MicroCabal package, the application is a second, and the TypeScript editor a
third with its own toolchain.

```text
micro-http/
  Makefile                     top-level orchestrator across the packages
  packages/
    micro-http/                the framework, a MicroCabal package
      micro-http.cabal
      src/
        MicroHttp.hs           framework facade
        MicroHttp/             framework modules
      cbits/                   framework C wrappers (fs, process)
      include/                 their headers (installed with the package)
    verso/                     the wiki application
      src/
        Verso/                 App.hs, Main.hs, ReplayTool.hs, Config.hs, ...
        Concordance/           the hybrid search engine
      cbits/                   the Concordance C shim and stub
      static/editor/           served editor bundles and vendored assets
    verso-editor/              the TypeScript editor and its toolchain
      src/                     editor source
      test/                    editor tests
      moebius/                 the generated-CSS tool
  test/
    unit/          MicroHttp/ and Verso/ framework and application specs
    integration/   MicroHttp/ and Verso/ specs that touch external effects
    bench/         throughput and rendering benchmarks
  docs/
  spike/           exploratory compile spikes
```

## MicroHttp Source Layout Conventions

Each Haskell package follows the familiar shape:

- `src/` for the package's modules, with module names mirroring file paths.
- `cbits/` and `include/` for its C sources and headers, beside `src/`.
- One `.cabal` file at the package root, built and installed with `mcabal`.
- `app/`-style executables stay in the application package's `src/Verso` for now
  (`Main.hs`, `ReplayTool.hs`).
- `test/` at the repository root holds the Haskell suites; `test/bench/` holds the
  benchmarks.

The framework is installed into the MicroHs package database and the application
resolves it from there, the same way `base` and `mtl` resolve; the Makefile
reinstalls it when its sources change.

Inside the application, the document tree's layout has one home: `Verso.TreePath`
(RFC-0044). A request path is parsed there once, in the handler, and every module
below the handler (`Verso.TreeMove`, `Verso.DocumentMeta`, `Verso.Draft`) takes the
resulting `TreePath` or `TrashId` value rather than a string. Parent, slug, kind,
section `index.md`, meta directory, peer `assets/` folder, served filesystem path
and trash entry directory are functions of that module and are not derived by
string arithmetic elsewhere. The path-safety rule itself stays in the framework as
`MicroHttp.Static.safeComponent`, shared with the static mount.

The tree's structural operations (create, move, delete, restore, undo) likewise have
one home, `Verso.Structure` (RFC-0045). It owns the transaction each performs over
its collaborators (the page source, the maintenance hooks, the operation and trash
stores, the versioning context and the revision commit), all fields of one record
the route table builds once. `Verso.TreeMove` beneath it is the filesystem
implementation; `Verso.App` above it parses a request, calls the operation and
renders the outcome. `test/integration/Verso/StructureSpec.hs` tests the
transaction through recording adapters, without a request.

The wiki's JSON API responses are built from a value, not concatenated strings:
`Verso.Json` is the small JSON tree and its one spec-correct renderer (RFC-0046).
Domain renderers and handlers build a `Json`; `App.jsonResponse` renders it at the
boundary. The one exception is the `/operations` endpoint, which splices the
persisted operation-log lines (`Verso.OperationLog.renderOperation`) verbatim.

The trash has one durable-mechanics module: `Verso.Trash` owns a trash entry's
provenance manifest and the filesystem operations on it (store, restore, list,
purge) (RFC-0047). `Verso.TreeMove` keeps the document-tree parts of delete and
restore -- the referrer check, the asset classification, the listing edits -- and
calls `Verso.Trash` for the entry mechanics. The warm catalogue `Verso.TrashStore`
and the retention sweep in `Verso.Structure` depend on `Verso.Trash`, not on the
move engine.

A structural operation tells the derived indexes what changed by emitting a
`Verso.Maintenance.Event` to a handler, rather than calling one of five named hooks
(RFC-0048). `Verso.App` builds the handler from the link-index and search adapters;
`Verso.Structure` and the content-save handlers emit the events. The git layer
surfaces a setup or staging failure as a typed result the caller logs, rather than
discarding it (ADR-0093): `Git.ensureRepository` returns `Either String RepoInit`
and `Git.commitPaths` returns `CommitFailed` on a staging failure.

Building a sized, streamed response from a file -- a prefix, the file through a
per-block transform, and a suffix, behind an exact `Content-Length` from a
pre-count pass -- is a framework capability: `MicroHttp.Http.transformedFileResponse`
(and its temp-file and in-memory siblings) owns the count and the missing-file
cleanup (RFC-0049). `Verso.App`'s document responses call it, supplying the HTML
escaper as the block transform. The response-body taxonomy is matched only inside
`MicroHttp.Http` (`writeResponse`, `serialiseResponse`, and `mapBody`, the one
place an egress stage rewrites a body); `MicroHttp.Middleware` and `Verso.App` no
longer name the body constructors.

The Markdown editor follows a source-vs-asset distinction:

- `packages/verso-editor/src/` contains TypeScript source for the application's
  web components, with its own tests under `packages/verso-editor/test/`.
- `packages/verso/static/editor/` contains files the application serves directly,
  including the generated JavaScript bundle and CSS.

Do not put TypeScript source under a `static/` directory; that is for served
assets.

## MicroHttp Spike Code Policy

Keep `spike/` as evidence and exploratory code. Do not import from `spike/` in
production modules.

When a spike result becomes production code, copy or rewrite it into a package's `src/` with
tests under `test/`. Do not gradually mutate spike modules into production
modules.

## MicroHttp Test Layout Decision

Use `test/unit/...` for unit specs and `test/integration/...` for specs that
touch the filesystem, sockets, subprocesses, environment, clock, or other
external effects. Within each suite, mirror `packages/micro-http/src/MicroHttp/...` module paths.

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
