# MicroHttp ADR Registry

## ADR Registry Purpose

This registry records architectural decisions for `micro-http`. Module design
documents may repeat local consequences, but durable rationale belongs here.

Each ADR uses this shape:

- Status.
- Context.
- Decision.
- Consequences.

## ADR Registry Decisions

### ADR-001: Use Small Public Modules

Status: Accepted.

Context: MicroHs support is exploratory, so FFI, parsing, rendering, routing, and
state decisions need to remain independently replaceable.

Decision: Keep public modules small and focused.

Consequences: `src/` contains `MicroHttp` plus focused `MicroHttp.*` modules
rather than one large framework module.

### ADR-002: Name the Socket Adapter `MicroHttp.Network.Socket`

Status: Accepted.

Context: The project needs a socket module because MicroHs does not provide the
expected `Network.Socket` API. Using `Network.Socket` would imply compatibility
with the Hackage package and create future import ambiguity.

Decision: Name the MicroHs socket adapter `MicroHttp.Network.Socket`.

Consequences: The server imports `MicroHttp.Network.Socket`; no production
module should expose raw socket FFI details.

### ADR-003: Keep Production Code Under `src/`

Status: Accepted.

Context: The spike code is useful evidence, but it contains proof-oriented
shortcuts and platform assumptions.

Decision: Keep production modules under `src/`.

Consequences: Production modules must be copied or rewritten into `src/`; they
must not import from `spike/`.

### ADR-004: Use Conventional Haskell Project Layout

Status: Accepted.

Context: `src/`, `test/`, `app/`, `bench/`, and one Cabal file are familiar to
Haskell readers and leave room for `mcabal` later.

Decision: Use a conventional Haskell project layout.

Consequences: Tests mirror `src/` module paths under `test/`; executable entry
points live in `app/`.

### ADR-005: Start Build Automation With `Makefile`

Status: Accepted.

Context: Direct `mhs` commands are the lowest-friction way to keep production
modules testable before package metadata stabilises.

Decision: Use `Makefile` as the first build automation entrypoint.

Consequences: `make check` is the standard quality gate. It runs documentation
linting, Haskell format checks, HLint, and production tests. Spike builds remain
available through dedicated targets, but they are historical or design checks
rather than part of the default gate. Cabal or MicroCabal can be added after
production modules settle.

### ADR-006: Start With a Small Local Test Harness

Status: Accepted.

Context: MicroHs documentation says common test packages can compile, but early
workspace setup had not verified installed test dependencies.

Decision: Start with a small local Hspec-shaped test harness.

Consequences: Pure modules can get tests immediately; moving to `HUnit` or
`hspec` remains an option after package verification.

### ADR-007: Keep Sockaddr Construction in Haskell First

Status: Accepted.

Context: The preference is to remain in Haskell. The spikes show Haskell-side
byte layout can work on macOS, and hiding it in one module limits the blast
radius.

Decision: Keep sockaddr construction in Haskell first.

Consequences: `MicroHttp.Network.Socket` owns all layout constants and pointer
writes. C helper functions are a fallback only if portability or safety problems
justify them.

### ADR-008: Use Strict `ByteString` at the Socket Boundary

Status: Accepted.

Context: HTTP wire data is bytes, and the socket layer should not force text
conversion or `String` allocation. MicroHs provides `ByteString` pointer helpers
that fit concrete `CString` FFI bindings.

Decision: Use strict `ByteString` at the socket boundary.

Consequences: `recv` returns `ByteString`; `sendAll` accepts `ByteString`; text
decoding belongs above the wire layer.

### ADR-009: Return `Either` for Fallible Socket Operations

Status: Accepted.

Context: The server needs to distinguish accept, read, write, bind, listen, and
close failures without crashing the whole process or hiding recoverable
conditions behind exceptions.

Decision: Return `Either` for fallible socket operations.

Consequences: Public socket operations return `IO (Either SocketError a)`;
negative FFI results are converted to `Left`.

### ADR-010: Do Not Add an External Streaming Library Yet

Status: Accepted.

Context: Streaming large responses is useful, but adding a streaming dependency
before the strict request/response path exists would create extra compatibility
work and design surface.

Decision: Do not add an external streaming library yet.

Consequences: Use a small local response-body shape for file streaming. Avoid an
external streaming package until MicroHs compatibility and actual pressure are
clear.

### ADR-011: Close Every Connection After One Request Initially

Status: Accepted.

Context: HTTP/1.1 keep-alive requires precise request framing and connection
reuse behaviour. The first server milestone should prove request handling before
persistence.

Decision: Close every connection after one request initially.

Consequences: The response layer emits `Connection: close`; persistent
connections are deferred.

### ADR-012: Build Value-Level Routing First

Status: Accepted.

Context: Value routing is enough for htmx endpoints and is simpler under MicroHs
extension constraints.

Decision: Build value-level routing first.

Consequences: `MicroHttp.Router` is production scope; `MicroHttp.Router.Typed` is
optional and layered.

### ADR-013: Keep HTML Rendering Pure and Monadic

Status: Accepted.

Context: A pure builder gives convenient composition without coupling rendering
to IO, state, sockets, or a heavyweight framework.

Decision: Keep HTML rendering pure and monadic.

Consequences: `MicroHttp.Html` exposes a local combinator API; handlers render
HTML values into response bodies.

### ADR-014: Use Filesystem-Backed State Before a Database

Status: Accepted.

Context: Initial application state does not need a traditional database, and a
filesystem adapter keeps persistence explicit and inspectable.

Decision: Use filesystem-backed state before a database.

Consequences: `MicroHttp.Store.FileSystem` owns atomic-write and serialisation
concerns; higher layers depend on a small store API.

### ADR-015: Model Middleware as Application Transformations

Status: Accepted.

Context: Middleware should stay optional and composable rather than becoming a
framework feature.

Decision: Model middleware as `Application -> Application` transformations.

Consequences: `MicroHttp.Middleware` wraps behaviours such as request logging or
error responses.

### ADR-016: Use a Closed Sum Type for HTTP Methods

Status: Accepted.

Context: The first server targets browser and htmx workflows. A closed method
type gives route matching and method override code simple, total pattern matches
without carrying arbitrary method text through the application.

Decision: Use a closed sum type for HTTP methods.

Consequences: The parser chooses the `Method` constructor at parse time. Unknown
or extension methods are rejected as unsupported input rather than preserved in
`Request`.

### ADR-017: Normalise Request Header Names at Parse Time

Status: Accepted.

Context: HTTP request header lookup is case-insensitive. Normalising once in the
parser keeps handlers, middleware, and body parsing from repeating the same
case-folding work.

Decision: Normalise request header names at parse time.

Consequences: `Headers` keeps a lower-case header-name invariant for requests.
The original request header spelling is not preserved.

### ADR-018: Support File Response Bodies in the First Implementation

Status: Accepted.

Context: File response support is useful for static assets and large content,
and the type-level cost is low if it is modelled as a `ResponseBody` variant.

Decision: Support file response bodies in the first implementation.

Consequences: `ResponseBody` includes a file case. Strict bodies can still be
serialised with `Content-Length`; file bodies are written by the server or
response writer in chunks. The first file response implementation should not
require an external streaming library. MicroHs does not currently export
`getFileSize`, so file responses may initially be close-delimited unless a small
file-size capability is added.

### ADR-019: Keep Markdown Parsing and Rendering in the Editor

Status: Accepted.

Context: The Markdown editor spike proved that htmx and web components can use a
plain Markdown field as the HTTP contract. Phase Three also showed that growing
parallel browser and server Markdown parsers creates duplication quickly. The
server does not need to own rich Markdown parsing to satisfy the core MicroHttp
goal; it can store and serve Markdown documents while the editor owns parsing,
rendering, validation, and preview behaviour.

Decision: Keep the MicroHttp server minimal for Markdown documents. The server
stores submitted Markdown and serves Markdown documents or static editor assets.
The editor owns Markdown parsing, rendering, preview, and visual editing. remark
and mdast are a development/reference contract for fixtures and expected
Markdown behaviour, not a production server runtime dependency.

Consequences: Server-side Markdown parsing should not grow beyond narrow spike
support unless a later ADR changes ownership. The current TestApp renderer is
spike evidence and should be treated as replaceable. Future editor work should
adapt browser-side libraries, such as remark or ProseMirror/Tiptap, behind the
`<markdown-editor>` custom element while keeping the HTTP/storage contract as
Markdown text.

## ADR Registry Open Review Items

- Verify socket layout assumptions on non-macOS platforms before treating
  Haskell-side sockaddr construction as portable.
- Confirm whether MicroHs `ByteString` performance and allocation behaviour are
  acceptable for socket reads and writes under load.
- Decide whether file responses need a local file-size FFI before static asset
  support is considered production-ready.
- Decide how much of the TestApp Markdown renderer should be removed once editor
  preview/rendering is fully browser-owned.
