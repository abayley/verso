# MicroHttp Design Decision Register

## Design Register Purpose

This register records architectural decisions for `micro-http`. Module design
documents may repeat the local consequences, but durable rationale belongs here.

## Design Register Decisions

### DEC-001: Use Small Public Modules

Status: Accepted.

Rationale: MicroHs support is exploratory, so small modules keep FFI, parsing,
rendering, routing, and state decisions independently replaceable.

Consequences: `src/` will contain `MicroHttp` plus focused `MicroHttp.*`
modules rather than one large framework module.

### DEC-002: Name the Socket Adapter `MicroHttp.Network.Socket`

Status: Accepted.

Rationale: The project needs a socket module because MicroHs does not provide
the expected `Network.Socket` API. Using `Network.Socket` would imply
compatibility with the Hackage package and create future import ambiguity.

Consequences: The server imports `MicroHttp.Network.Socket`; no production
module should expose raw socket FFI details.

### DEC-003: Keep Production Code Under `src/`

Status: Accepted.

Rationale: The spike code is useful evidence, but it contains proof-oriented
shortcuts and platform assumptions.

Consequences: Production modules must be copied or rewritten into `src/`; they
must not import from `spike/`.

### DEC-004: Use Conventional Haskell Project Layout

Status: Accepted.

Rationale: `src/`, `test/`, `app/`, `bench/`, and one Cabal file are familiar
to Haskell readers and leave room for `mcabal` later.

Consequences: Tests mirror `src/` module paths under `test/`; executable entry
points live in `app/`.

### DEC-005: Start Build Automation With `Makefile`

Status: Accepted.

Rationale: Direct `mhs` commands are the lowest-friction way to keep MicroHs
spikes reproducible before package metadata stabilises.

Consequences: The first automation target is `make check`; Cabal or MicroCabal
can be added after production modules settle.

### DEC-006: Start With a Small Local Test Harness

Status: Accepted.

Rationale: MicroHs documentation says common test packages can compile, but
this workspace has not yet verified installed test dependencies.

Consequences: Pure modules can get tests immediately; moving to `HUnit` or
`hspec` remains an option after package verification.

### DEC-007: Keep Sockaddr Construction in Haskell First

Status: Accepted.

Rationale: The preference is to remain in Haskell. The spikes show Haskell-side
byte layout can work on macOS, and hiding it in one module limits the blast
radius.

Consequences: `MicroHttp.Network.Socket` owns all layout constants and pointer
writes. C helper functions are a fallback only if portability or safety problems
justify them.

### DEC-008: Use Strict `ByteString` at the Socket Boundary

Status: Accepted.

Rationale: HTTP wire data is bytes, and the socket layer should not force text
conversion or `String` allocation. MicroHs provides `ByteString` pointer helpers
that fit concrete `CString` FFI bindings.

Consequences: `recv` returns `ByteString`; `sendAll` accepts `ByteString`; text
decoding belongs above the wire layer.

### DEC-009: Return `Either` for Fallible Socket Operations

Status: Accepted.

Rationale: The server needs to distinguish accept, read, write, bind, listen,
and close failures without crashing the whole process or hiding recoverable
conditions behind exceptions.

Consequences: Public socket operations return `IO (Either SocketError a)`;
negative FFI results are converted to `Left`.

### DEC-010: Do Not Add an External Streaming Library Yet

Status: Accepted.

Rationale: Streaming large responses is useful, but adding a streaming
dependency before the strict request/response path exists would create extra
compatibility work and design surface.

Consequences: Use a small local response-body shape for file streaming. Avoid an
external streaming package until MicroHs compatibility and actual pressure are
clear.

### DEC-011: Close Every Connection After One Request Initially

Status: Accepted.

Rationale: HTTP/1.1 keep-alive requires precise request framing and connection
reuse behaviour. The first server milestone should prove request handling before
persistence.

Consequences: The response layer emits `Connection: close`; persistent
connections are deferred.

### DEC-012: Build Value-Level Routing First

Status: Accepted.

Rationale: Value routing is enough for htmx endpoints and is simpler under
MicroHs extension constraints.

Consequences: `MicroHttp.Router` is production scope; `MicroHttp.Router.Typed`
is optional and layered.

### DEC-013: Keep HTML Rendering Pure and Monadic

Status: Accepted.

Rationale: A pure builder gives convenient composition without coupling
rendering to IO, state, sockets, or a heavyweight framework.

Consequences: `MicroHttp.Html` exposes a local combinator API; handlers render
HTML values into response bodies.

### DEC-014: Use Filesystem-Backed State Before a Database

Status: Accepted.

Rationale: Initial application state does not need a traditional database, and a
filesystem adapter keeps persistence explicit and inspectable.

Consequences: `MicroHttp.Store.FileSystem` owns atomic-write and serialisation
concerns; higher layers depend on a small store API.

### DEC-015: Model Middleware as Application Transformations

Status: Accepted.

Rationale: Middleware should stay optional and composable rather than becoming a
framework feature.

Consequences: `MicroHttp.Middleware` wraps `Application -> Application`
behaviours such as request logging or error responses.

### DEC-016: Use a Closed Sum Type for HTTP Methods

Status: Accepted.

Rationale: The first server targets browser and htmx workflows. A closed method
type gives route matching and method override code simple, total pattern matches
without carrying arbitrary method text through the application.

Consequences: The parser chooses the `Method` constructor at parse time.
Unknown or extension methods are rejected as unsupported input rather than
preserved in `Request`.

### DEC-017: Normalise Request Header Names at Parse Time

Status: Accepted.

Rationale: HTTP request header lookup is case-insensitive. Normalising once in
the parser keeps handlers, middleware, and body parsing from repeating the same
case-folding work.

Consequences: `Headers` keeps a lower-case header-name invariant for requests.
The original request header spelling is not preserved.

### DEC-018: Support File Response Bodies in the First Implementation

Status: Accepted.

Rationale: File response support is useful for static assets and large content,
and the type-level cost is low if it is modelled as a `ResponseBody` variant.

Consequences: `ResponseBody` includes a file case. Strict bodies can still be
serialised with `Content-Length`; file bodies are written by the server or
response writer in chunks.

The first file response implementation should not require an external streaming
library. MicroHs does not currently export `getFileSize`, so file responses may
initially be close-delimited unless a small file-size capability is added.

## Design Register Open Review Items

- Verify socket layout assumptions on non-macOS platforms before treating
  Haskell-side sockaddr construction as portable.
- Confirm whether MicroHs `ByteString` performance and allocation behaviour are
  acceptable for socket reads and writes under load.
- Decide whether file responses need a local file-size FFI before static asset
  support is considered production-ready.
