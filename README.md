# MicroHttp

MicroHttp is a small HTTP/1.1 server library for MicroHs. It is aimed at
server-rendered HTML applications that use htmx and web-component markup without
depending on GHC-only web frameworks.

The project is currently an early implementation. It has production modules in
`src/`, exploratory spikes in `spike/`, and design notes in `docs/`.

## MicroHttp Project Goals

MicroHttp is intended to provide:

- Plain TCP HTTP/1.1 serving for MicroHs applications.
- A small `Request -> IO Response` application boundary.
- Explicit `Either`-based network and response-write failures.
- Strict `ByteString` request and response handling for the first version.
- File-body response support for serving larger content without loading it into
  one strict response value.
- Pure, monadic HTML rendering helpers for server-rendered pages and fragments.
- Value-level routing first, with typed routing left as a later design track.
- Filesystem-backed state in the next implementation stage.

The project deliberately avoids:

- Template Haskell.
- Type families.
- Heavy framework dependencies.
- TLS, HTTP/2, and WebSockets in the first version.
- A database dependency in the first version.

## MicroHttp Repository Layout

```text
micro-http/
  src/               Production modules.
  test/unit/         Unit specs with no filesystem or socket effects.
  test/integration/  Integration specs that use filesystem or socket effects.
  spike/             Exploratory compile spikes retained for design evidence.
  docs/              Design documents and the decision register.
```

The current public facade is `MicroHttp`, which re-exports:

- `MicroHttp.Html`
- `MicroHttp.Http`
- `MicroHttp.Http.Parser`
- `MicroHttp.Http.Response`
- `MicroHttp.Router`
- `MicroHttp.Server`

The network adapter is currently exposed as `MicroHttp.Network.Socket`, but it is
not re-exported through the public facade.

## MicroHttp Installation

Install MicroHs, MicroCabal, development tools, and the current test dependencies
before running the project checks. The full installation notes are in
[INSTALL.md](INSTALL.md).

The Makefile expects `mhs`, `hlint`, `fourmolu`, and `markdownlint-cli2` to be
visible on `PATH`. Test targets pass the MicroHs package database explicitly:

```make
MHS = mhs
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.0.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
```

## MicroHttp Build Commands

Run the full project gate:

```sh
make check
```

`make check` runs:

- Markdown linting for root Markdown files and `docs/`.
- Fourmolu format checks for `src/` and `test/`.
- HLint checks for `src/` and `test/`.
- Unit and integration test executables under `test/`.
- TypeScript editor linting, Knip unused-code checks, type checking, tests, and
  bundling.

Run only Markdown linting:

```sh
make docs
```

Run only Haskell format checks:

```sh
make format-check
```

Format Haskell source and test files:

```sh
make format
```

Run only HLint:

```sh
make lint
```

Run all tests:

```sh
make test
```

Run the browser smoke test for the Markdown editor spike:

```sh
make test-editor-browser
```

The browser smoke test starts and stops the TestApp itself.

Run the TypeScript editor checks:

```sh
make editor-check
```

Run only the TypeScript editor unused-code check:

```sh
make editor-knip
```

The editor source lives under `src/TestApp/Editor/`. Bun compiles it into the
generated, untracked served bundle at `static/editor/markdown-editor.js`.

Format TypeScript and editor package files with Biome:

```sh
make editor-format
```

Biome uses four-space indentation and a 120-character line length for the editor
tooling.

Run unit tests only:

```sh
make test-unit
```

Unit tests must not perform filesystem, socket, subprocess, environment, clock,
or other external I/O. They may use `IO` when the effect is local and in-memory,
such as `IORef`-backed writer capture.

Run integration tests only:

```sh
make test-integration
```

Integration tests cover behaviour that needs real external effects, currently
file-body response writing and socket listen/close behaviour.

Generate developer-only coverage reports with GHC and HPC:

```sh
make coverage
```

Coverage is a secondary signal. The production compatibility gate remains the
MicroHs-based `make check` target. The coverage target writes unit and
integration HTML reports under `build/coverage/*/report/`.

Compile all retained spikes:

```sh
make all-spikes
```

Spikes are retained as historical design evidence. They are not part of the
default `make check` quality gate. Compiled spike binaries are written under
`build/`.

Remove generated binaries:

```sh
make clean
```

## MicroHttp Run Commands

Run the test application:

```sh
make run-test-app
```

Then open:

```text
http://127.0.0.1:8080/
```

The app is implemented in `src/TestApp.hs` and serves `/`, `/index.html`, the
Markdown editor spike under `/documents/home/edit`, and static editor assets
under `/static/editor/`. The editor web-component source is TypeScript under
`src/TestApp/Editor/`; `make run-test-app` depends on `make editor-build`, which
writes the generated served JavaScript bundle.
The app uses the normal `serve` loop. The socket adapter keeps listening and
client sockets non-blocking so browser-style concurrent asset requests do not
starve handler progress under MicroHs' socket FFI.

The current server entrypoints are library functions:

- `serve :: Settings -> Application -> IO (Either ServerError ())`
- `serveOne :: Settings -> Application -> IO (Either ServerError ())`

For now, use the tests as executable examples of the public seams:

- `test/unit/MicroHttp/ServerSpec.hs` exercises request parsing through the
  server application boundary.
- `test/unit/MicroHttp/RouterSpec.hs` exercises route matching and handlers.
- `test/unit/MicroHttp/HtmlSpec.hs` exercises monadic HTML rendering.

An example application target should be added once the filesystem state module
exists.

## MicroHttp Documentation

Useful design documents:

- [Starter Design](docs/design/starter-design.md)
- [Module Design Index](docs/module-index.md)
- [ADR Registry](docs/decision-register.md)
- [Build Automation Design](docs/design/build-automation.md)
- [Project Organisation](docs/design/project-organisation.md)
- [Markdown Editor Spike Design](docs/design/markdown-editor-spike.md)
- [Network Design](docs/design/network-design.md)
- [RFC-0001: Editor Progressive Enhancement](docs/rfcs/rfc-0001-editor-progressive-enhancement.md)
- [RFC-0002: Editor Shell Decomposition](docs/rfcs/rfc-0002-editor-shell-decomposition.md)
- [RFC-0003: Socket Payload Correctness and Testability](docs/rfcs/rfc-0003-socket-correctness-and-testability.md)
- [RFC-0004: Iteratee Streaming IO](docs/rfcs/rfc-0004-iteratee-streaming-io.md)

New design decisions should be recorded in
[ADR Registry](docs/decision-register.md), not only in comments or chat.
