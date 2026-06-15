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

### ADR-020: Use Tiptap for Visual Markdown Editing

Status: Accepted.

Context: The hand-built `contenteditable` visual surface proved the htmx and
web-component integration path, but each Markdown feature adds DOM parsing,
editing, and serialisation complexity to the custom element. The next editor
phase also needs toolbar controls, raw Markdown editing, syntax highlighting,
and future table/image/attachment workflows. Tiptap is framework-agnostic and
can run behind the existing custom element boundary. Its Markdown extension is
currently beta, so it should be introduced behind an adapter rather than becoming
an unwrapped project-wide contract.

Decision: Use Tiptap/ProseMirror for the visual editing surface inside
`<markdown-editor>`. Keep Markdown text as the htmx/server contract. Keep
remark/mdast as the reference parser and validation fixture while Tiptap
Markdown support settles. Use CodeMirror for the future raw Markdown editor.
Use Web Awesome, the successor home for Shoelace, for future web-component UI
controls. Consider Lit for the editor shell once toolbar state, mode switching,
and nested controls make manual DOM management hard to follow.

Consequences: The next implementation slice should replace the visual
`contenteditable` surface with a Tiptap adapter while preserving existing source
mode, split mode, autosave events, and form submission behaviour. Toolbar,
CodeMirror, Web Awesome, and Lit integration should remain separate slices so the
editing-engine migration can be verified independently.

### ADR-021: Progressively Enhance the Editor Page

Status: Proposed.

Context: The editor page is currently an empty shell that requires JavaScript
to fetch and submit the document, which relegates the server to a minimal API
role and leaves script-less browsers with an unusable page. The project wants
MicroHttp to stay a reasonably general-purpose server for server-rendered
htmx applications, with rich client components as islands of interactivity
rather than the default architecture.

Decision: Serve `GET /documents/:id/edit` as a complete, working Markdown
form: a `<textarea name="markdown">` with the document content inside the
`<markdown-editor>` element. Capable browsers upgrade the page in place: the
element adopts the textarea content, participates in form submission through
`ElementInternals`, and provides the rich editing experience. The post
handler answers both ordinary form posts (post-redirect-get, full-page
validation re-render) and htmx posts (status fragments). The design is
RFC-0001.

Consequences: The server renders meaningful HTML for every client and owns
document delivery again; the separate document fetch and the hidden
`markdown` input are removed. The raw-Markdown textarea keeps the ADR-019
contract: the server still does not parse or render Markdown. Handlers must
branch on the `hx-request` header, and the browser smoke coverage must
include a JavaScript-disabled pass.

### ADR-022: Keep HTML Authoring in Haskell Combinators

Status: Accepted.

Context: MicroHs does not support Template Haskell, so compile-time-checked
template systems in the Hamlet/Shakespeare style are unavailable; a template
engine here would be a runtime string parser with runtime failures and a
second escaping discipline. The htmx application style composes many small,
conditional, parameterised fragments, which suits function composition. The
recognised future case for templates is an external designer producing HTML
files with content placeholders, in the Heist or Mustache style; that need
does not exist in the project today.

Decision: Keep the pure monadic HTML combinators (`MicroHttp.Html`,
ADR-013) as the canonical and only HTML authoring mechanism. Defer any
template engine until a concrete designer-authored-HTML need appears.

Consequences: All pages and fragments are authored as combinator values, and
escaping stays centralised in one renderer. If a template engine is added
later, it should parse template files at application start into the existing
`Html` value type, so rendering and escaping remain single-sourced and
templates become a front end to the combinators rather than a parallel
system.

### ADR-023: Frame Requests With an Incremental Reader

Status: Accepted.

Context: The server reads a request with a single `recv` of at most one
buffer, so requests split across TCP segments or larger than the buffer are
truncated, and the configured body limit is unreachable. The HTTP parser is
pure and should stay free of IO, so completeness must be established before
parsing.

Decision: Frame requests with an incremental reader that consumes chunks
from an injected source until the header terminator and the declared
`Content-Length` are satisfied, enforcing header and body limits as data
arrives. `recv` returning an empty `ByteString` is the orderly end-of-stream
signal. The design and test plan are RFC-0003.

Consequences: The reader is unit-testable with scripted chunk sources and
becomes the chunk seam for future streaming request bodies. The parser
continues to receive complete request bytes. One request per connection
(ADR-011) and the chunked-transfer-encoding rejection are unchanged.

### ADR-024: Stream Bodies With Iteratees and Enumerators

Status: Accepted.

Context: Request handling after RFC-0003 is correct but strict: memory is
proportional to message size, and response bodies other than files are
strict values. The project wants constant-memory streaming on both sides
without an external streaming library (ADR-010) and without producer
pushback: the design discussion settled on the iteratee model, where
residual input lives in the consumer's result and flows forward through
monadic bind, enumerators own resource acquisition and release, and
enumerators return the consumer's final state, which a future keep-alive
loop needs.

Decision: Implement a local iteratee core (`Stream e`, `Iter e a`,
`Enumerator e a`, concrete `ByteString` and `IO`) in a domain-free module
`MicroHttp.Iteratee`. The failure type is a parameter: the core machinery
only propagates failures, never constructs them, so the concrete error sum
`StreamError` (read/write transport, parse/limit, and producer-acquire
failures) lives in the domain layer `MicroHttp.Stream`. Resource bracketing
is expressed once as a general `resourceEnumerator` and reused by
`fileEnumerator`. Producers are enumerators (socket, file, strict value),
consumers are iteratees (framing, handlers, the socket
sink), and stream transformations are enumeratees. The `Application`
contract becomes `RequestHead -> Iter Response`, with the body consumed as
a stream and `ResponseBody` gaining a streaming variant. Middleware keeps
its `Application -> Application` shape (ADR-015); stream-touching
middleware lifts enumeratees onto the ingress or egress pipeline. The
design and migration plan are RFC-0004.

Consequences: Bodies of any size are handled in constant memory. The body
limit relocates from central parsing to a default size-cap stage in the
server pipeline, and handlers wanting strict bodies state an explicit
bound; the declared `Content-Length` is still checked against the cap
before any body bytes are read. The iteratee continuation is pure, with
effects confined to an explicit effect constructor, so the `Monad`
instance can feed residue eagerly; the failure type is a parameter, with
the domain vocabulary (`StreamError`) covering read, write, parse, and
producer-acquire failures and retiring RFC-0003's `FrameError`. The pure
parser shrinks to header bytes only. The
`Application` and router payload types change, and TestApp handlers
migrate. Unconsumed body bytes are disposed of by the server's
close-per-connection policy until keep-alive is revisited.

### ADR-025: Thread Socket Adapter Errors With ExceptT

Status: Accepted.

Context: `MicroHttp.Network.Socket` acquires resources in sequences where
every step is fallible and every failure after the file descriptor is
created must close it. Expressed as explicit `Either` case-matches this
nests five levels deep in `listenTcp`, repeating the same close-and-return
cleanup at each level, which is hard to read and easy to get wrong. The
project avoids heavy frameworks, but `mtl` and `transformers` are small,
dependency-light libraries already present and compiled in the MicroHs
package database, not frameworks in that sense.

Decision: Thread the socket adapter's acquire sequences through
`ExceptT SocketError IO` internally, with a single `closingOnError`
combinator that closes the descriptor if any later step fails. `ErrorT`
(`Control.Monad.Error`) is not used: it is removed in `mtl` 2.3 and was
always the wrong tool. The public operations keep their
`IO (Either SocketError a)` signatures (ADR-009 is unchanged); `runExceptT`
produces that type at the module boundary.

Consequences: Production code gains an `mtl` dependency, used only inside
the socket adapter. The deep case-staircases in `listenTcp`, `accept`,
`connectTcp`, and `boundPort` become linear do-blocks, and the
file-descriptor cleanup on a mid-acquisition failure is expressed once
rather than at every failure site. Those cleanup paths require a forced
syscall failure to exercise and remain unit-untested; they are preserved
by construction. Other modules continue to use plain `Either`/`Iter`
results; this ADR does not adopt monad transformers project-wide.

### ADR-026: Wait For Socket Readiness Via The Runtime Poll Queue

Status: Accepted.

Context: The socket adapter's would-block retry loops slept a fixed 1 ms
(`threadDelay`) before retrying, the RFC-0003 workaround for the
single-OS-thread runtime where a blocking syscall would freeze everything.
The post-RFC-0004 benches showed this caps request/response turnaround at
~50 MB/s against a ~2.3 GB/s saturated ceiling: an operation hits `EAGAIN`
once, sleeps a millisecond, then finds the data already present. The
MicroHs runtime already maintains a `poll()`-based I/O wait queue and
exposes `waitForReadFD`/`waitForWriteFD` (`IO.waitrdfd`/`IO.waitwrfd`)
under `WANT_IO_POLL`, which the unix runtime enables.

Decision: On a would-block result, park the current green thread on the
runtime poll queue with `waitForReadFD` (`recv`, `accept`) or
`waitForWriteFD` (`sendAll`, `connectTcp`) and retry, instead of
`threadDelay`. Sockets stay non-blocking; the public
`IO (Either SocketError a)` interface is unchanged (ADR-009). The design
is RFC-0005.

Consequences: Request/response throughput rises about 20-30x (the
single-threaded ping-pong bench moved from ~50 MB/s to ~1-1.5 GB/s),
toward the saturated ceiling, with no busy-poll. The single-OS-thread
cooperative model is preserved: no operation blocks in a syscall; only the
scheduler blocks, in one `poll()` over every waiting descriptor. The
runtime's `MAX_POLL_FDS` (100) now bounds simultaneously-waiting
descriptors, so it and `settingsMaxActiveHandlers` (32) should be kept
consistent. The forked-thread ByteString-corruption bug recorded in
RFC-0003 is orthogonal and unaddressed.

### ADR-027: Bound Idle Reads With A Timeout

Status: Accepted.

Context: After ADR-026 a would-block read parks indefinitely on the runtime
poll queue, so a stalled or silent peer holds a handler thread and an
active-handler slot until it acts (the slowloris exhaustion case). The wait
primitive (`waitForReadFD`) has no deadline. Two preconditions are now met:
the MicroHs `forkIO` ByteString-corruption bug no longer reproduces on the
installed toolchain (so the fork-based `System.Timeout` is sound), and
`timeout` interrupts a thread parked in `waitForReadFD` (verified by a spike
on a never-ready descriptor).

Decision: Bound the idle wait between reads, not each read. `recvWithin`
takes an idle timeout; when a read would block it waits with
`timeout n (waitForReadFD fd)` and reports a reached deadline as a timeout
`SocketError` (`isTimeoutError`). `socketEnumerator` maps that to a
`StreamTimeout` stream error, and the server answers `408 Request Timeout`.
`recv = recvWithin 0` keeps existing callers unchanged.
`settingsIdleReadTimeoutMicros` defaults to 30 s; a non-positive value
disables it. The design is RFC-0006.

Consequences: A slow or silent peer's read is bounded, freeing the handler
and its QSem slot. A timer thread is forked only when a read would actually
block, so steady transfers keep the ADR-026 throughput. The default
behaviour changes from an indefinite wait to a finite 30 s one; operators
can disable it. The bound is per idle wait, not a total-request budget, and
covers both the header and body reads. A write/idle-send timeout for slow
readers on the response path is deferred.

### ADR-028: Bound Idle Writes With A Timeout

Status: Accepted.

Context: ADR-027 bounded the read path but left the symmetric hole on the
write path. After the application produces a response, the server writes it
with `sendAll`; if the client stops reading, the kernel send buffer fills,
`sendAll` parks indefinitely on `waitForWriteFD` (ADR-026), and the handler
thread and its active-handler slot are held for as long as a slow reader
chooses, the same exhaustion vector in the other direction. The mechanism is
already proven: `waitForWriteFD` parks on the same poll queue, and the
runtime's `thread_intr` unlinks a parked thread regardless of read or write
intent, so the ADR-027 fork-based `timeout` reaches it unchanged. Unlike the
read side, a write timeout can happen after the response head is on the wire,
so there is no status-code answer; the only correct action is to close.

Decision: Bound the idle wait before a would-block write, mirroring ADR-027.
`sendAllWithin` takes an idle timeout; when a send would block it waits with
`timeout n (waitForWriteFD fd)` and reports a reached deadline as a timeout
`SocketError` (`isTimeoutError`). `sendAll = sendAllWithin 0` keeps existing
callers unchanged. The server's `socketResponseWriter` is the single writer
for both strict and streaming response bodies, so threading the timeout
through it bounds every write; a timed-out write surfaces as the existing
`ServerWriteFailed` and the connection closes, with no new error case or
response. `settingsIdleWriteTimeoutMicros` defaults to 30 s; a non-positive
value disables it. The design is RFC-0008.

Consequences: A slow or stalled reader can no longer hold a handler thread or
its QSem slot indefinitely; with ADR-027 and ADR-028, neither a slow sender
nor a slow reader can. A timer thread is forked only when a write would
actually block, so a draining peer keeps the egress throughput. The default
becomes a finite 30 s write wait rather than indefinite; operators can
disable it. The bound is per idle wait, not a total-response budget, and
covers the response head and body, including a streaming `StreamBody`. A
timeout variant of the non-server `socketSinkI` is deferred until a caller
needs it.

### ADR-029: Access Log At The Connection Layer

Status: Accepted.

Context: The server emitted nothing observable per request. An access log
needs both the request line (method, path) and the write outcome (status,
bytes, latency, and whether the connection failed). These live at different
layers: the application middleware (`Application -> Application`) sees the
head but runs only after the head parses, so it never observes a connection
that stalls or resets mid-headers and cannot guarantee a line per
connection. `handleClient` is the outermost layer and reaches a terminal
outcome for every accepted connection, so it is the only layer that can log
all of them. A wall-clock millisecond source (`getTimeMilli`) is available
in the `mhs` lib, adequate for latency.

Decision: Put the access log at the connection layer. `handleClient` times
the request, captures the parsed head via an `onHead` callback the pipeline
runs on a successful parse, counts the bytes `socketResponseWriter` sends,
and emits a `RequestReceived` event when the head parses and a terminal
event after the write: `RequestCompleted` (with the written status,
including the 400/408 paths) for a sent response, or `RequestAborted` for a
transport failure, so no connection is unlogged. The logger is an injected
`AccessEvent -> IO ()` sink with a swappable formatter (`formatLogfmt` the
logfmt default); `settingsLogger` defaults to `nullLogger` (off). The
`MicroHttp.Log` module depends only on `MicroHttp.Http`, so `AccessEvent`'s
abort case carries a short String label rather than the server's
`ServerError` -- the server imports `MicroHttp.Log` for the `Settings`
field, and carrying `ServerError` would make that an import cycle. The
design is RFC-0009.

Consequences: Every accepted connection produces a terminal log line, and a
parsed request also produces a received line, giving a standard access log
once an operator supplies a logger. `Settings` drops its unused
`deriving (Eq, Show)` because a `Logger` is a function; nothing in the
project compared or showed a `Settings`. When no logger is set the added
cost is two `getTimeMilli` reads and a byte counter per request, behind the
disabled path; the logger is off by default so the prior behaviour and the
benches are unchanged. The peer address (a `getpeername` FFI) and a
timestamp field are deferred to the injected sink or a follow-up.

Follow-up: every logfmt line now leads with a local-time timestamp,
`ts=YYYY-MM-DDThh:mm:ss.mmm±zzzz`, captured by `logfmtTo` at emit and rendered
by `localTimestamp`. It uses a `localtime`/`strftime` FFI rather than `Data.Time`
on purpose: the bundled `time` package compiles under `mhs` but its local-time
conversion is wrong on this toolchain (it negates the zone offset, e.g. NZST
renders as `-1200` with the wrong calendar day), whereas `localtime` delegates
to libc and is correct.

### ADR-030: Static File Serving As A Safe Wildcard Route

Status: Accepted.

Context: Static serving was a hand-rolled whitelist in TestApp
(`staticEditorAsset`), with no generic handler and no path-safety story for an
arbitrary root. A general handler needs prefix routing, path-traversal safety,
a 404 decided before the response head, and a content-type map. Two
environment facts shaped the scope: `getFileSize` is not exposed by the `mhs`
libraries, so a `Content-Length` would need a new FFI; and the parser splits
the path on `/` before percent-decoding each segment, so `%2e%2e` arrives as a
literal `..` segment and `%2f` decodes to a `/` inside a single segment.

Decision: Add a terminal wildcard `PathPart` (`Rest`, pattern `*name`) to the
router, capturing the remaining segments. `MicroHttp.Static` provides `static`
(a route constructor mounting a root under a prefix) and `serveStatic`. The
served path is built from the request's already-decoded `requestPath` segments
beyond the mount, not from a rejoined capture, and each component is rejected
if it is empty, `.`, `..`, or contains a path separator or NUL -- which
defeats both literal and `%2e%2e`/`%2f` traversal. Existence is checked with
`doesFileExist` and `doesDirectoryExist` before the head, so a missing file or
a directory is a clean 404, never a 200 head that fails mid-stream. The
content-type is chosen by extension (default `application/octet-stream`), and
the body streams close-delimited as a `StreamBody` over `fileEnumerator` (no
`Content-Length`). TestApp is migrated off the whitelist. The design is
RFC-0010.

Consequences: A generic, traversal-safe static handler is reachable as an
ordinary route, and a reverse proxy can still shadow it in production. Because
the 404-before-head check stats the filesystem, routing a static request is
now an IO action; TestApp's editor-asset serving tests therefore moved from
the unit suite (which forbids filesystem effects) to integration. Deferred to
a later FFI-backed RFC: `Content-Length`, keep-alive, conditional requests
(`ETag`/`If-Modified-Since`), and symlink-escape detection (which needs
`realpath`). A dotfile under the root is served if present, so the operator
must curate the served root.

### ADR-031: Delegate Edge Concerns To A Fronting Reverse Proxy

Status: Accepted.

Context: MicroHttp is designed to run behind a reverse proxy (nginx or similar)
in production. A cluster of edge concerns are handled better, and more
securely, at that proxy than in a small MicroHs server, and building them in
process would bloat the server for no gain on the proxied path. We choose
explicitly which of these we will not build, so the boundary is a decision
rather than a backlog.

Decision: The following are the proxy's responsibility and are deliberately not
built into MicroHttp: TLS termination; HTTP/2 and HTTP/3 (the upstream link
stays HTTP/1.1); client keep-alive (we send `Connection: close` per response,
matching nginx's default connection-per-request upstream mode -- RFC-0012
non-goal); body compression such as gzip or brotli (we never compress a
response body in process, which is also why a `sendfile` `FileBody` being
opaque to `egress` costs nothing -- RFC-0014); static asset caching and CDN
edge; request rate limiting and per-IP connection caps; and slow-client /
connection-flood (slow-loris) edge protection. MicroHttp keeps a lightweight
backstop for proxy-less deployments only: the idle read and write timeouts
(ADR-027, ADR-028) bound a single stalled connection and
`settingsMaxActiveHandlers` caps concurrency, but the fuller edge protection is
the proxy's. The boundary is documented in
`docs/design/starter-design.md` (Reverse Proxy Boundary).

Consequences: the server stays small and close-per-request, and a proxied
deployment gains TLS, keep-alive, compression, caching, and slow-loris
protection without any of that code in MicroHttp. Proxy-less deployments (local
development, the desktop packaging) run without those, retaining only the
timeout backstop -- acceptable for trusted or low-exposure use. Because nothing
is compressed in process, an `egress` middleware that ever wants to transform a
`FileBody` opts out of zero-copy by replacing the body (RFC-0014) rather than
the framework needing a compression path. Should a proxy-less production target
ever become first-class, keep-alive and the heavier protections would need
their own RFCs.

### ADR-032: Application As A Stream Consumer, Logging As Middleware

Status: Accepted. Supersedes ADR-029.

Context: Framing ran in a server-owned pipeline above the application and
outside the middleware stack, and request logging was special-cased inside
`handleClient` because the old `Application = RequestHead -> Iter` only ran
after a head parsed -- so a middleware there could not see a connection that
failed before parsing, nor the request bytes.

Decision: `Application` becomes `ConnectionInfo -> Iter StreamError Response` --
it consumes the raw request stream and receives the connection's non-payload
metadata (the peer). Framing, parsing, and the body bound move into the
application stack as `Router.serveRoutes`/`frameAndParse`, with routing the
innermost layer; `route` stays handler-facing (`Captures -> RequestHead ->
...`). `Middleware = Application -> Application` is a stream-level transformer;
`withErrorResponses` maps a parse failure to 400 and an idle-read timeout to
408 (a read failure stays an abort), and `logRequests` is the outermost
middleware -- it taps the first line for the peer/method/target, times the
request, counts request bytes, and emits the access-log events. `handleClient`
collapses to: drive the stack, write the response, close. `ConnectionInfo`
lives in `MicroHttp.Network.Socket` and is decoded by `accept` from the
`sockaddr` it already fills (no `getpeername`).

Consequences: logging is an ordinary middleware that sees the request bytes
and the response, so the connection-layer special case (ADR-029) is gone and
`settingsLogger` is removed; the application composes `logRequests`. The body
bound and the 400/408 responses are now application-composed
(`serveRoutes`/`withErrorResponses`), so `Settings.maxBodyBytes` is the value
an application threads into its limits rather than something the server
enforces directly. `ServerError` gains `ServerStreamFailed` for a stream
failure that produced no response. The initial landing deferred two pieces that
a follow-up then added: `RequestHead` now carries `requestPeer`, filled by the
router from the connection and built via an `emptyRequestHead` default so the
field addition was a one-line change rather than touching every construction
site; and `logRequests` now logs response bytes -- exact for a strict body
(from its serialised length) and counted through an egress stage for a
streaming body (the head length plus the body bytes, logged when the body
finishes). The design is RFC-0012.

### ADR-033: Configuration Via A key=value File With Environment Overrides

Status: Accepted.

Context: After RFC-0012 the operator-tunable knobs are split between the server
`Settings` (host, port, limits, timeouts) and the application composition (the
access-log path, document root, static mounts, parse limits), and both were
hardcoded. An operator needs to configure these without recompiling. MicroHs
has no TOML/JSON/YAML parser, so the format must be something trivially parsed
in-project.

Decision: A `MicroHttp.Config` module parses a flat `key = value` file (blank
lines and `#` comments ignored, whitespace trimmed; a non-blank line without an
`=` is a `ConfigError`). `applyEnvironment` overlays `MICROHTTP_<KEY>`
environment entries onto the parsed config, winning over the file; precedence is
defaults, then file, then environment. `toSettings` maps the known server keys
onto `defaultSettings`, failing fast on a bad value; `configString`/`configInt`/
`configBool` read application keys with defaults, and `configMounts` parses a
comma-separated `<prefix> <root>` list for multiple static mounts. The
executable's `main` loads the config (path from `MICROHTTP_CONFIG`, default
`micro-http.conf`), builds the `Settings`, and composes the application from the
same config; a missing file uses defaults, a malformed file exits non-zero.
The design is RFC-0011.

Consequences: zero-config still runs on defaults, and an operator configures via
a readable file or environment overrides. The config store is open (no fixed
schema), so the RFC's "warn on unknown keys" was dropped -- with app-defined
keys there is no closed key set to warn against. Environment overrides read
`getEnvironment`, which reflects variables present at launch (the production
case); under MicroHs a mid-process `setEnv` is not seen because `environ` is
snapshotted, so the override logic is unit-tested through the pure
`applyEnvironment` rather than a live `setEnv`. No secrets live in the config;
TLS remains the reverse proxy's concern (ADR-031).

### ADR-034: Zero-Copy File Responses Via sendfile, With The Size Carried

Status: Accepted.

Context: Static files streamed through `StreamBody (fileEnumerator path)`,
copying every byte kernel -> userspace -> kernel and (ADR-030) carrying no
`Content-Length` because `mhs` exposes no `getFileSize`. `sendfile(2)` copies a
file descriptor to a socket in-kernel and, with the file size, gives an exact
length.

Decision: Add `FileBody FilePath Int` to `ResponseBody` -- the path and its size
in bytes. The size is resolved once, where the body is built: `serveStatic`
already stats for the 404 decision, so it also sizes the file (via `lseek` to
`SEEK_END`, the single new size FFI, exposed as `fileSizeBytes`) and carries the
result on the constructor. Both the response head's `Content-Length` and the
access-log byte count read that one carried number, with no second syscall. The
response writer grows from a bare `ResponseWriter` into a `ResponseSink` with a
`sinkChunk` (head/strict/stream) and a `sinkFile`; the socket `sinkFile` opens
the file, writes the head with the carried size, `sendfile`s the body bounded by
the idle write timeout (`sendFileWithin`, mirroring `sendAllWithin`), and closes
the fd. The in-memory test sink reads the file and replays it through
`sinkChunk`. Because the bytes go kernel-to-kernel, an `egress` stage cannot
rewrite a `FileBody` in place; `fuseBody` passes it through, and a middleware
that wants the content replaces the body with a `StreamBody`/`StrictBody`. The
portable, transformable fallback `StreamBody (fileEnumerator …)` stays public.
macOS only initially (the `sendfile` signature differs on Linux -- the RFC-0007
seam). The design is RFC-0014.

Consequences: Static responses are zero-copy and length-delimited, closing the
deferred `Content-Length` gap and making file responses keep-alive-eligible (when
keep-alive lands; `Connection: close` still sent). The RFC's original plan had
the sink `lseek` for the size; carrying it on the body instead gives a single
source of truth shared by the head and the log without the log re-opening the
file. `Range`/partial content and Linux `sendfile` are later work. The
symlink-escape limitation (ADR-030) is unchanged.

### ADR-035: Graceful Close Drains The Receive Buffer To Avoid An RST Truncation

Status: Accepted.

Context: An application may answer without consuming the whole request (RFC-0012
lets the response resolve from the head alone). On macOS/BSD, `close()` on a
socket that still has unread receive data sends a `RST` instead of a `FIN`, and
that `RST` can race the peer's read and discard data the peer has buffered but
not yet read -- truncating the response. The bug is timing-dependent (it bit
under load) and was invisible until RFC-0014's end-to-end test asserted the
exact response bytes; earlier tests only checked that the status line was
present, which survives truncation.

Decision: Before closing a client connection, `handleClient` calls
`closeClientSocketGraceful`, which drains whatever is currently in the receive
buffer with a non-blocking sweep (read until a read would block, end of stream,
or error) and then closes. With no unread receive data, the close is an orderly
`FIN` that delivers the queued response. The sweep never waits for the peer, so
it cannot stall the handler, and it is the same for every response, not just a
`FileBody`.

Consequences: Responses are no longer truncated by an `RST` when the handler
left request bytes unread -- a latent correctness bug fixed for all bodies, and
the precondition for `sendfile` file responses (RFC-0014) to arrive intact. The
drain only clears bytes already buffered; a client still trickling a body the
application ignored could in principle leave data unread, but that is the same
best-effort lingering-close behaviour common to connection-close servers, and
the bounded sweep keeps the handler responsive.

### ADR-036: Editor Visual Themes As A Token Axis

Status: Accepted.

Context: The Markdown editor had one appearance axis -- light/dark, toggled by
`wa-light`/`wa-dark` on `<html>`. Its surface is already token-driven (a full
set of `--markdown-editor-*` custom properties under `:root` and `:root.wa-dark`
in `markdown-editor.css`), and a round of redesign mockups (`docs/mockups/`)
showed several distinct looks worth offering. The goal was to make the editor
themeable without coupling a visual choice to the light/dark axis or to new
editor behaviour.

Decision: Add a `data-editor-theme` attribute on `<html>` as a visual-theme axis
orthogonal to the colour scheme. A theme overrides the `--markdown-editor-*`
tokens for both schemes (`:root[data-editor-theme="x"]` and its `.wa-dark`
variant), with an optional structural-CSS layer scoped under the same selector
for effects tokens cannot express (gradients, glass, grids, ruled paper, status
chrome). An absent or unknown value is the default Paper look, so existing
behaviour is unchanged. A `wa-dropdown` in the toolbar selects the theme; the
theme and the colour scheme persist in `localStorage`, resolved (validated) on
connect, and a pre-paint inline bootstrap applies the stored preference before
first paint from a fixed allowlist so there is no flash. An `editor_theme`
config key (RFC-0011) supplies the first-visit default; precedence is stored
preference, then config default, then Paper, validated server-side to Paper. A
theme may also set a small set of bounded layout presets the editor already
supports (Workbench opens in Split; the source pane's line numbers come from
CodeMirror's `basicSetup`); presets are defaults, not locks. The initial set is
Paper, Aurora (neutral frosted glass), Blueprint (cyanotype/white-print grid),
Herbarium (ruled-paper journal), and Workbench (IDE). The design is RFC-0015.

Consequences: themes are a thin, mostly-CSS axis layered on the existing token
and colour-scheme machinery, so adding one is a token block plus an optional
structural layer, registered in four places (the CSS, the dropdown list, the
server allowlist, and the bootstrap allowlist). Genuinely new interactions are
out of scope for a theme: Studio (mockup C) -- defined by a selection bubble
toolbar and a slash-command menu -- is deferred to a later round (the parked Lit
spike) rather than shipped as a half-version. `backdrop-filter` themes degrade
to flat translucency where unsupported.

## ADR Registry Open Review Items

- Verify socket layout assumptions on non-macOS platforms before treating
  Haskell-side sockaddr construction as portable.
- Confirm whether MicroHs `ByteString` performance and allocation behaviour are
  acceptable for socket reads and writes under load.
- Port `sendfile` to Linux (different signature) and add `Range`/partial-content
  and conditional requests (`ETag`/`If-Modified-Since`) for file responses; the
  exact `Content-Length` from the file size is now in place (ADR-034, RFC-0014).
- Decide how much of the TestApp Markdown renderer should be removed once editor
  preview/rendering is fully browser-owned.
