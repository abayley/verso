# MicroHttp

MicroHttp is a small HTTP/1.1 server library for MicroHs, plus Verso, a
Markdown wiki application built on it. It targets server-rendered HTML
applications with web-component markup and fetch-based mutations, without
depending on GHC-only web frameworks.

## MicroHttp Project Goals

The framework provides:

- Plain TCP HTTP/1.1 serving for MicroHs applications.
- A streaming application boundary,
  `RequestHead -> Iter StreamError Response`: handlers receive the parsed
  request head and consume the body through a local iteratee/enumerator core,
  so bodies of any size are handled in constant memory
  ([RFC-0004](docs/rfcs/implemented/rfc-0004-iteratee-streaming-io.md)).
- Explicit `Either`-based network and response-write failures.
- Strict `ByteString` request and response handling, with file-body and
  zero-copy sendfile responses for larger content.
- Pure, monadic HTML rendering helpers for server-rendered pages and
  fragments.
- Value-level routing.
- Static file serving, configuration loading, request logging with rotation,
  and a fork/exec process seam.

The project deliberately avoids:

- Template Haskell and type families.
- Heavy framework dependencies.
- TLS, HTTP/2, and WebSockets.
- A database dependency; application state is filesystem-backed.

## MicroHttp Repository Layout

```text
micro-http/
  packages/micro-http/     The web framework, a MicroCabal package (HTTP,
                           sockets, server, router, and its cbits).
  packages/verso/          The Verso wiki application: src/Verso and
                           src/Concordance, the Concordance C shim (cbits),
                           and the served static assets (static/). Depends on
                           the micro-http package.
  packages/verso-editor/   The TypeScript editor, built into
                           packages/verso/static/editor/.
  test/unit/               Unit specs with no filesystem or socket effects.
  test/integration/        Integration specs that use filesystem or socket effects.
  test/ghc-compat/         Shims that let the suites also build under GHC for coverage.
  test/bench/              Throughput and rendering benchmarks.
  scripts/                 Repository tooling: the ADR and RFC index generators.
  data/                    Runtime state: the default document tree and its derived
                           indexes, logs, drafts, and trash (mostly gitignored).
  patches/                 Patches applied to vendored dependencies.
  docs/                    Documentation; docs/README.md is the map of what goes where.
  spike/                   Exploratory compile spikes retained for design evidence.
```

Two directories are generated and gitignored: `build/` (compiled binaries, objects, and coverage
reports) and `vendor/` (the vendored native search libraries; see `make search-*`).

The framework lives under the `MicroHttp` namespace, the wiki application
under `Verso`, and the search engine under `Concordance`; `Verso.*` depends
on `MicroHttp.*` and `Concordance.*`, never the reverse (RFC-0030,
RFC-0034).

The public facade is `MicroHttp`, which re-exports `MicroHttp.Html`,
`MicroHttp.Http`, `MicroHttp.Iteratee`, `MicroHttp.Middleware`,
`MicroHttp.Router`, `MicroHttp.Server`, and `MicroHttp.Stream`. The remaining
top-level modules (`Config`, `FileSystem`, `Log`, `Process`, `Settings`,
`Static`, and `Network.Socket`) are imported directly.

## Verso Wiki Application

Verso is a filesystem-backed Markdown wiki assembled in `packages/verso/src/Verso/App.hs`:

- Documents under `/documents/:id` render read-only by default; `?edit` opens
  the editor and `?raw` serves the Markdown source.
- A navigation tree lists, creates, moves, and deletes documents. Moves and
  deletes are in-server operations recorded in an operation log, with undo and
  a trash area.
- Images and attachments upload alongside a document, with sidecar metadata
  and an attachments panel in the editor.
- A persisted link index keeps intra-wiki links consistent across moves and
  deletes (`POST /index/refresh` rebuilds it).
- Git-backed versioning provides drafts, publish, revision history, diff, and
  rollback.
- Hybrid search (semantic embeddings plus BM25 full text, fused with
  reciprocal rank fusion) over published pages at `/search`, kept fresh by a
  background re-index queue. Search is optional: it needs the Concordance
  engine (`Concordance.*`, LanceDB and ONNX Runtime behind a small C shim)
  built via `make search-shim`, and is off by default (`search_enabled`).

## Verso Frontend Architecture

The server renders HTML pages; mutations are fetch requests with status/JSON
responses (RFC-0036: `PUT`/`DELETE` on pages and drafts, POST controllers for
domain operations). Markdown text is the wire contract between browser and
server -- saves carry it as the raw request body -- and the server never
parses Markdown (ADR-0019). A plain form post remains the no-JavaScript floor.

The editor is a `<markdown-editor>` web component, written in TypeScript under
`packages/verso-editor/src/`:

- Tiptap/ProseMirror provides the visual editing surface (ADR-0020); custom
  nodes and marks cover tables, images, footnotes, admonitions, collapsible
  sections, badges, reference links, and raw HTML.
- CodeMirror provides the raw Markdown source mode.
- remark/mdast is the browser-side reference parser and serialiser for
  Markdown round-tripping.
- Lit implements the UI shell elements: toolbar, bubble toolbar, command bar,
  slash menu, link popover, and table controls, with Web Awesome supplying
  base controls.
- Code fences are syntax-highlighted with lowlight; `mermaid` fences render
  diagrams from a lazily loaded separate bundle (RFC-0033).

Bun bundles the editor into the generated, untracked
`packages/verso/static/editor/markdown-editor.js`. Biome (four-space indent, 120-character
lines), tsc, Vitest, and Knip gate the TypeScript via `make editor-check`.

## MicroHttp Installation

Install MicroHs, MicroCabal, development tools, and the current test
dependencies before running the project checks. The full installation notes
are in [INSTALL.md](INSTALL.md).

The Makefile expects `mhs`, `hlint`, `fourmolu`, and `markdownlint-cli2` on
`PATH`, and passes the MicroHs package database explicitly:

```make
MHS = mhs
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.5.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
```

## MicroHttp Build Commands

Run the full project gate:

```sh
make check
```

`make check` runs:

- Markdown linting for root Markdown files and `docs/`.
- Fourmolu format checks and HLint for the Haskell sources and `test/`.
- Unit and integration test executables under `test/`.
- TypeScript editor linting, Knip unused-code checks, type checking, tests,
  and bundling.

Individual targets:

- `make docs` — Markdown linting only.
- `make format` / `make format-check` — format Haskell sources / check only.
- `make lint` — HLint only.
- `make test` / `make test-unit` / `make test-integration` — all, unit-only,
  or integration-only tests.
- `make editor-check` — the TypeScript editor gate; `make editor-format`,
  `make editor-knip` for individual steps.
- `make test-editor-browser` — Playwright browser smoke test for the editor;
  it starts and stops the Verso server itself.
- `make test-ghc-smoke` — the same smoke against the GHC build of the server
  (`build/ghc/verso`), the one check that both compilers' binaries behave
  alike end to end.
- `make coverage` — developer-only GHC/HPC coverage reports under
  `build/coverage/*/report/`. Coverage is a secondary signal; the
  compatibility gate remains the MicroHs-based `make check`.
- `make run-verso-ghc` — developer-only: build the server with GHC
  (`build/ghc/verso`) and run it on the same config as `run-verso`. The
  shipped binary is the MicroHs one; this exists for GHC's tooling.
- `make run-verso-ghc-prof` — the GHC profiling build; on exit (Ctrl-C) it
  leaves `build/ghc-prof/verso.prof` (time and allocation by cost centre) and
  `verso.hp` (heap over time, `hp2ps -c` renders it). `VERSO_GHC_PROF_RTS`
  selects the RTS profile flags. Read a GHC profile for algorithmic hot spots
  and allocation shape; the MicroHs cost model (interpreted per-byte work,
  the fixed cell heap) does not apply to it.
- `make clean` — remove generated binaries.

Unit tests must not perform filesystem, socket, subprocess, environment,
clock, or other external I/O. They may use `IO` when the effect is local and
in-memory, such as `IORef`-backed writer capture.

Throughput and rendering benchmarks (`make bench-*`) are described in
[MicroHttp Benchmarks](docs/reference/benchmarks.md).

The optional search engine builds via `make search-lancedb` (patched
lancedb-c dylib; needs Rust), `make search-model` (checksum-pinned model
download), and `make search-shim` (the C shim; needs ONNX Runtime via
Homebrew). Without them a no-dependency stub is linked and search reports
itself unavailable; `make check` never needs the search toolchain
(RFC-0034).

## Verso Run Commands

Run the Verso application:

```sh
make run-verso
```

Then open:

```text
http://127.0.0.1:8080/
```

`make run-verso` depends on `make editor-build`, which writes the served
editor bundle. The socket adapter keeps listening and client sockets
non-blocking so browser-style concurrent asset requests do not starve handler
progress under MicroHs' socket FFI.

The server entrypoints are library functions:

- `serve :: Settings -> Application -> IO (Either ServerError ())`
- `serveOne :: Settings -> Application -> IO (Either ServerError ())`

The tests are executable examples of the public seams:
`test/unit/MicroHttp/ServerSpec.hs` (request parsing through the application
boundary), `test/unit/MicroHttp/RouterSpec.hs` (route matching), and
`test/unit/MicroHttp/HtmlSpec.hs` (monadic HTML rendering).

## MicroHttp Documentation

[docs/README.md](docs/README.md) maps what each documentation directory holds and where a new document
goes. Useful entry points:

- [Starter Design](docs/architecture/starter-design.md)
- [Module Design Index](docs/reference/module-index.md)
- [Configuration Reference](docs/reference/configuration.md)
- [ADR Registry](docs/adrs/index.md)
- [Project Organisation](docs/architecture/project-organisation.md)
- [Build Automation Design](docs/architecture/build-automation.md)
- [Network Design](docs/architecture/network-design.md)

RFCs live under `docs/rfcs/`: open proposals at the top level, completed work
in `docs/rfcs/implemented/`, and abandoned proposals in `docs/rfcs/rejected/`.

New design decisions should be recorded in the
[ADR Registry](docs/adrs/index.md), not only in comments or chat.
