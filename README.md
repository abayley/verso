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

Install MicroHs, MicroCabal, and the current test dependencies before running the
project checks. The full installation notes are in
[INSTALL.md](INSTALL.md).

The Makefile expects this sibling workspace layout:

```text
haskell/
  MicroHs/
    bin/mhs
  micro-http/
    Makefile
```

The test targets pass the MicroHs package database explicitly:

```make
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.0.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
```

## MicroHttp Build Commands

Run the full project gate:

```sh
make check
```

`make check` runs:

- Markdown linting for `README.md`, `INSTALL.md`, and `docs/`.
- Unit and integration test executables under `test/`.
- All compile spikes under `spike/`.

Run only Markdown linting:

```sh
make docs
```

Run all tests:

```sh
make test
```

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

Compile all retained spikes:

```sh
make all-spikes
```

Remove generated test and spike binaries:

```sh
make clean
```

## MicroHttp Run Commands

There is not yet a standalone example executable in `app/`. The current server
entrypoints are library functions:

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

- [Starter Design](docs/starter-design.md)
- [Module Design Index](docs/module-index.md)
- [Decision Register](docs/decision-register.md)
- [Build Automation Design](docs/build-automation.md)
- [Project Organisation](docs/project-organisation.md)

New design decisions should be recorded in
[Decision Register](docs/decision-register.md), not only in comments or chat.
