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
structural layer, registered in three places (the CSS, the editor dropdown list,
and the server allowlist); the pre-paint bootstrap's allowlist is derived from
the server list rather than duplicated. Genuinely new interactions are
out of scope for a theme: Studio (mockup C) -- defined by a selection bubble
toolbar and a slash-command menu -- is deferred to a later round (the parked Lit
spike) rather than shipped as a half-version. `backdrop-filter` themes degrade
to flat translucency where unsupported.

### ADR-037: Studio Editor Surfaces As Hand-Rolled Popovers Over Existing Commands

Status: Accepted.

Context: Studio (mockup C), deferred by ADR-036/RFC-0015, is defined by two new
interactions rather than colour: a selection bubble toolbar (formatting raised
over a non-empty selection) and a slash command menu (blocks inserted by typing
`/`). The persistent command bar is removed in this look. The open question was
whether these surfaces need a Tiptap menu package or the long-deferred Lit
adoption (ADR-019), or whether the editor's existing machinery suffices. An
interaction spike (`docs/design/editor-studio-spike.md`) showed the existing
hand-rolled popover positioning and the proven block/inline/structure commands
are enough.

Decision: Ship Studio as a sixth visual theme (registered the same three ways as
the others: token block, dropdown entry, server allowlist) plus one bounded
behavioural preset, `themeUsesStudioSurfaces`, that in visual mode hides the command bar (a host
`markdown-editor--studio-surfaces` class, not a teardown) and activates the two
surfaces. The surfaces are visual-pane only, so source and split mode keep the
command bar (the source pane needs it); the class re-evaluates on mode change.
The bubble toolbar and slash menu are built as general editor capabilities in
`markdown-editor-element.ts`, reusing the existing `positionOverlay` helper and
the existing `toggleInlineStyle`/`applyBlockStyle`/`toggleStructure` paths, and
are only activated under Studio this round. The bubble carries a block-style
selector (Paragraph, Heading 1-3) alongside the inline controls, so an existing
line can be converted in place without the command bar; this is needed because
the bar is hidden in visual mode and the slash menu only fires on an empty `/`
block. The bubble observes a document
`selectionchange` listener and reads the DOM selection; the slash menu detects
the trigger and resolves the caret block through `posAtDOM` on the DOM caret (the
same basis as the existing commands), not ProseMirror's selection state, with
capture-phase keyboard navigation. No Tiptap menu package and no Lit are added.
The mockup's document sidebar and multi-document breadcrumb are not shipped: they
imply a backend that does not exist, so Studio carries only chrome backed by data
the editor already has (matching Workbench's precedent). The design is RFC-0016.

Consequences: Studio is additive -- existing themes, the colour-scheme axis, and
the command bar under every other theme are unchanged; switching theme is a class
flip with no editor rebuild, so content and save state are preserved. The two
surfaces are general enough to enable under other themes later without rework.
Lit stays deferred (ADR-019); revisit only if popover/menu state grows well
beyond these two surfaces. Anchoring detection on the DOM caret keeps the
surfaces testable under happy-dom, consistent with the existing command tests.

### ADR-038: HTML Rendering As A Coalesced ByteString Builder

Status: Accepted.

Context: `MicroHttp.Html` was a writer monad over `String`
(`newtype Html a = Html (String, a)`, `>>=` doing `left ++ right`), and the
TestApp rendered it then copied the whole page with `BS.pack` into a strict
body -- repeated `[Char]` appends plus a whole-page copy. A measurement spike
(`bench/HtmlBuilderBench.hs`, `make bench-html-builder`) on mhs 0.16.3.0
compared representations and, crucially, measured the socket cost: a difference
list of `ByteString` renders 12-24% faster than the `String` writer, but
emitting one `sinkChunk` (one `sendAll`) per fragment costs ~70x the syscalls of
one buffer-sized write. The 0.16.3.0 toolchain also fixes the `ByteString`
corruption fault that made a ByteString-heavy renderer risky (ADR review item,
`docs/microhs-bytestring-bug-report.md`). The design is RFC-0013.

Decision: Render HTML through a difference-list builder of `ByteString`
(`newtype Builder = Builder ([ByteString] -> [ByteString])`, O(1) append by
composition); `Html` keeps its writer shape with the accumulator swapped from
`String` to `Builder`, and the combinator API is unchanged. Constant tag and
escape fragments are pre-packed CAFs; only dynamic, escaped text packs per
render, coalescing runs of safe characters into one chunk. `renderHtml ::
Html a -> String` is retained (byte-identical to the old renderer, pinned by the
`HtmlSpec` golden cases) for tests and `String` callers; `renderChunks ::
Html a -> [ByteString]` coalesces the builder output into >=16 KB segments
before the socket -- one segment for a typical page -- so the write count stays
as low as the old single `sendAll`. The TestApp builds HTML responses from
`renderChunks` concatenated into one `StrictBody`. A `ChunksBody [ByteString]`
that streams a large page's segments without a page-sized allocation is
specified but deferred: no current page approaches the buffer (the editor shell
is ~1.2 KB).

Consequences: HTML responses drop the `[Char]` appends and the whole-page
pack-copy for a 12-24% CPU win, with no change to the rendered bytes or the
socket write count, and no new dependency (no `Data.ByteString.Builder` under
mhs). Coalescing is the contract, not raw per-fragment streaming, which the
spike showed is a ~70x socket-write pessimisation -- the lesson mirrors
blaze-html's buffer-filling builder. `renderHtml`'s `String` is now derived from
the chunks (`concatMap BS.unpack`), so it round-trips through Char8, matching the
wire bytes the `BS.pack` step already produced.

### ADR-039: Editor Edit Page As Progressive Enhancement

Status: Accepted.

Context: The edit page was a script-only shell -- it rendered an htmx form, the
`<markdown-editor>` fetched the document through a `src` attribute, and the
Markdown reached the server through a hidden input populated on the htmx
`configRequest` event. A browser without JavaScript got a blank page. RFC-0001
made the page work without scripting and upgrade in place.

Decision: `GET /documents/:id/edit` server-renders a real form
(`action`/`method` plus the htmx attributes) containing a
`<textarea name="markdown">` with the current document inside the
`<markdown-editor>` element, and a `<noscript>` submit button. `POST
/documents/:id` answers both modes from one route, branching on the `hx-request`
header: htmx keeps the status-fragment behaviour; an ordinary post follows
post-redirect-get (`303` to the edit page) on success and re-renders the edit
page with the validation message and the escaped submission on failure. Form
posts have their CRLF newlines normalised to LF so the document contract stays
line-feed only. On upgrade the element adopts the textarea (disabling and hiding
it but keeping it in the DOM), becomes a form-associated custom element
(`static formAssociated`, `attachInternals` guarded for runtimes without
support) and keeps its value current with `setFormValue`; the displayed document
name comes from an explicit `data-document` attribute. The hidden input is
removed; the `configRequest` hook is kept only to set the htmx request parameter
(a robust complement to `ElementInternals`, since `FormData` already carries the
element's value). The design is RFC-0001.

Consequences: the editor works with JavaScript disabled (textarea form, ordinary
post, redirect) and is unchanged when enhanced (autosave, save states,
validation, shortcuts). One route serves both submission modes; one value source
(the element, or the textarea without scripting) avoids the duplicate-`markdown`
hazard that blocked a literal phase split, so the page-structure and element
changes landed together. `src` is no longer used on the edit page but remains
supported for embedding. The textarea fallback page carries no design
investment beyond legibility (ADR-019/ADR-022 stand: no server-side Markdown
rendering, no templating engine).

### ADR-040: No-JavaScript Reading Is Raw Markdown; Rendering Stays Browser-Owned

Status: Accepted.

Context: RFC-0001 (ADR-039) added a no-JavaScript editing fallback: without
scripting, a document is edited as raw Markdown in a textarea and read as raw
Markdown (the `GET /documents/:id` response is `text/markdown`). The question
arose whether to extend the fallback to a *formatted reading* view, which would
require turning Markdown into HTML on the server -- a second renderer alongside
the browser's. The server currently has no Markdown-to-HTML renderer at all
(ADR-019): it serves Markdown raw and only validates it on save.

Decision: Keep the no-JavaScript experience as raw Markdown end to end; do not
add a server-side Markdown renderer. Rendering stays browser-owned (ADR-019
reaffirmed). Without JavaScript, MicroHttp is a raw-Markdown CRUD app; with
JavaScript, it is the rich editor -- a consistent progressive-enhancement seam.
The server's save-time Markdown validation (raw-HTML rejection, supported-block
subset check) is retained as a trust-and-integrity guard, not a renderer: it
defends against untrusted client input and keeps stored documents within the
editor's round-trippable subset. There is therefore nothing to "remove" -- the
server has no renderer, and the validation stays.

Consequences: one Markdown renderer in the system (the browser's), forever; no
divergence risk and no cross-language sync burden. The no-JavaScript reader (a
marginal audience: scripting off, very old browsers, some text-mode/privacy
setups) sees legible raw Markdown rather than formatted HTML, an honest
degradation that matches Markdown's plain-text legibility. This holds only while
the no-JavaScript *reader* is a graceful-degradation case rather than a
first-class user; if formatted server-rendered reading ever becomes a product
requirement (a content/publishing thesis where readers without JavaScript are
first-class), that is a different product and warrants its own RFC, with the
server renderer kept in sync with the editor subset through a shared golden
corpus.

Alternatives considered:

- A server-side Markdown-to-HTML renderer (option B in the discussion): rejected.
  It is a second implementation of the editor's Markdown subset across a language
  boundary mhs cannot bridge (it cannot run the JS renderer), so it must be kept
  in sync by hand; the sync tax is permanent and grows with every editor feature
  (tables, etc.). A shared golden corpus makes it *manageable*, not free, and it
  cuts against the editor-as-island direction (ADR-019/ADR-031).
- Persisting client-rendered HTML at save time (option C): rejected. A
  no-JavaScript save stores Markdown the client renderer never processed, so the
  cached HTML drifts from the Markdown with no way to self-heal; a cache that can
  go stale and cannot recover is worse than no cache.

### ADR-041: Editor Content Extensions, And The Server Guard As A Trust Boundary

Status: Accepted.

Context: Adding a Markdown block or inline type to the editor (RFC-0017) used to
thread through a closed, exhaustive `switch` in each of several representations
(model union, mdast-to-model parse, model-to-HTML render, DOM-to-model and
model-to-Markdown serialise, the Tiptap node), every one of which threw on an
unknown type, plus the Haskell save-time `supportedBlock` guard. Arbitrary
extensions were impossible without editing core files for each one. Separately,
ADR-040 retained the server's save-time validation as "raw-HTML rejection plus a
supported-block subset check"; with a client-extensible, open subset that subset
check becomes the cross-language dual-implementation trap ADR-040 itself rejected
for rendering (the Haskell recogniser cannot track arbitrary client extensions).

Decision: (1) Introduce a content-extension registry: each extension is one
module registering handlers for the seams it needs (parse, render, serialise in
and out for both blocks and inlines, a document-level render, and remark
plugins), and the core dispatchers became fail-soft registry walks over an open
model (`CustomBlock` / `CustomInline`); the built-in subset is the always-present
fallback extension. Parse seams stay strict (an unknown mdast node throws,
preserving the raw-HTML guard); render and serialise seams fail soft. (2) Adopt
Lit for the editor's *view layer only* (the toolbar, bubble, slash menu, link
popover, and the extensions' chrome -- table controls, callouts, collapsible
toggle), while the controllers, the registry, and the Tiptap/CodeMirror adapters
stay framework-agnostic; Lit already ships via Web Awesome, so this is no new
runtime dependency. (3) Narrow the Haskell `MicroHttp.TestApp` save-time guard to
raw-HTML rejection only, dropping block-structure validation. The editor is the
authority on its own open subset; the server defends the trust boundary, not the
grammar.

Consequences: a new editor feature is a new module plus one `registerExtension`
call, with zero edits to the core dispatchers (proven by GFM tables, GFM
admonitions, mkdocs collapsibles, and GFM footnotes, all landed this way). Raw
HTML stays uniformly rejected, so the server never trusts client Markdown to be
safe; but it no longer constrains document *structure*, so editor subset growth
no longer needs a coordinated Haskell change (the dual-implementation trap is
closed, consistent with ADR-040/ADR-019). The narrowing is a behaviour change --
the server now accepts Markdown the old block check rejected (e.g. an unterminated
code fence) -- covered by `MicroHttp.TestApp` tests. Each extension carries its
own per-extension golden tests (parse, render, DOM-serialise, round-trip) as the
correctness net, since the server no longer validates structure.

Refines ADR-040: that ADR's retained validation was "raw-HTML rejection plus a
supported-block subset check"; the subset check is now removed. The raw-HTML
rejection and the browser-owned-rendering stance are unchanged.

### ADR-042: Attachments As A Content-Addressed Blob Store Served As Untrusted Bytes

Status: Accepted.

Context: RFC-0018 adds images and file attachments. The editor needed a way to
get binary bytes from the user to the server and reference them from Markdown,
but the only `POST` body the app parsed was `application/x-www-form-urlencoded`
(the document save), and raw HTML stays uniformly rejected (ADR-040/041), so
`<img>`/`<a>` tags are not an option. Serving untrusted user bytes safely is the
sharp edge: an uploaded HTML or SVG blob served inline as same-origin content is
the classic stored-XSS vector. The existing static serving (ADR-018/030/034)
already had the safe, zero-copy half of the problem solved.

Decision: (1) Upload is a raw-body `POST /attachments` from the editor's `fetch`
(the `File` is the body; the filename rides a percent-encoded
`X-Attachment-Filename` header), not multipart -- multipart needs a streaming
boundary parser for a scripted interaction, and the existing bounded
`readBodyStrict` reader is reused unchanged. No-JavaScript upload is deferred
(no-JS users reference already-uploaded URLs by typing). (2) Storage is a
content-addressed blob store mirroring `DocumentStore`: bytes are written once to
`<root>/<hash>` under a non-cryptographic 128-bit FNV-1a hash (MicroHs has no
crypto library); the write is direct, not temp-then-rename (no `renameFile` in
MicroHs), which content-addressing makes idempotent and self-healing. The
original filename is *not* stored -- it travels in the serving URL
(`/attachments/<hash>/<name>`) where it drives the content type and the download
name, keeping the store a pure blob directory with no parallel index. (3) Serving
is the proven zero-copy `FileBody`/`sendfile` path plus a fixed hardening header
set on every response: the URL-derived `Content-Type`, `X-Content-Type-Options:
nosniff`, `Content-Security-Policy: default-src 'none'; sandbox`, immutable
caching (safe because content-addressed), and `Content-Disposition: inline` only
for the inline-renderable image types (png/jpeg/gif/webp) with `attachment`
(download) for everything else -- SVG included, since it can carry script. The
hash segment is validated as 32 lowercase hex digits; the cosmetic name never
touches the filesystem, so `Static`'s path-safety is preserved. A type allow-list
gates uploads (`415` otherwise) and a per-upload size bound returns `413`; the
global framing cap `settingsMaxBodyBytes` was raised to at least that bound.

Consequences: the server now accepts and serves arbitrary user bytes -- a new
trust boundary -- but the bytes can neither execute nor be re-interpreted
(nosniff + sandbox CSP + download disposition for non-image types), cannot
overwrite or escape (content-addressing + hex-validated path), and are bounded in
size and type. The hash is for dedup and addressing, not security -- safety is the
serving headers and the allow-list, so a non-cryptographic hash is acceptable.
Orphaned blobs (a document edited to drop an image) are tolerated in v1; a
mark-sweep GC over documents' referenced hashes, and quotas/rate-limiting (in-app
or via the fronting proxy, ADR-031), are deferred. Images render from Markdown
`![]()` via a content extension (ADR-041); no raw HTML is introduced, so the
save-time guard is unchanged.

Extends ADR-034 (zero-copy `sendfile`) and ADR-030 (safe static serving) to a
write path; rides ADR-014 (filesystem-backed stores) and ADR-031 (edge concerns
at the proxy). Consistent with ADR-040/041 (raw HTML stays rejected).

### ADR-043: Image Dimensions As A `{width=N}` Markdown Attribute List

Status: Accepted.

Context: Images (ADR-042, RFC-0018) needed a resize capability, which means a way
to persist a display size. Markdown has no native image-size syntax, and the
project uniformly rejects raw HTML at save time (ADR-040/041), so `<img width>`
is not an option -- it would reopen the trust hole that guard exists to close. A
size is only meaningful if it round-trips through the saved Markdown (visual ->
Markdown -> reload), so it must live in a Markdown representation, not in editor
state alone. Candidates: a Pandoc/`attr_list` attribute list
(`![alt](src){width=N}`), an Obsidian-style pipe in the alt text
(`![alt|N](src)`), or a query parameter on the URL handled by the serving layer.

Decision: persist the size as a Pandoc-style attribute list immediately following
the image -- `![alt](src "title"){width=N}` -- carried on the existing image
content extension (ADR-041). The source pipeline parses it with a small remark
transform that lifts a leading `{width=N}` off the text after an image onto the
image node and consumes that text; render emits an escaped `<img ... width="N">`;
serialise emits `{width=N}`; the DOM serialise seam reads the `width` attribute
back. The visual editor's Tiptap image node gains a `width` attribute, a drag
handle node view that commits the dragged width to it, and a post-load pass that
applies a `{width=N}` left as literal text by marked (which has no attribute-list
support) -- mirroring how the other non-CommonMark syntaxes are pre/post-processed
around marked. v1 stores width only (height auto, aspect ratio preserved) in
integer pixels; display is bounded to the editor width by CSS so an over-wide
value never overflows, while the stored value is preserved.

Consequences: image sizing stays inside the Markdown subset and the
content-extension registry -- no raw HTML, no new server route, no
attachment-layer transcoding -- so the save-time guard and browser-owned
rendering (ADR-040) are unchanged. The attribute list is a documented, portable
Markdown convention; the no-JavaScript raw-Markdown view shows the literal
`{width=N}` text, which is acceptable (it is raw Markdown). The pipe-in-alt
alternative was rejected (it corrupts the alt text and collides with a literal
`|`); the URL-parameter alternative was rejected (it pushes resizing into the
serving layer -- an RFC-0018 non-goal). `height`, percentage widths, and a numeric
width control alongside the drag handle are natural later extensions of the same
`{...}` syntax.

Builds on ADR-041 (content-extension registry) and ADR-042 (the images it sizes);
consistent with ADR-040 (raw HTML rejected, browser-owned rendering).

### ADR-044: Editor View Preferences Persist Client-Side In localStorage

Status: Accepted.

Context: The editor carries view preferences that should survive across sessions
-- the colour scheme (light/dark/match-system), the visual theme (ADR-036), and
now an adjustable editing-column width (Narrow/Medium/Wide/Full, since the fixed
default felt narrow). These are presentation choices with no bearing on document
content. The question for the width preference (and the pattern in general) was
where to keep it: a cookie (sent to the server) or client-side storage.

Decision: persist editor view preferences client-side in `localStorage`, one
key per preference (`editor-color-scheme`, `editor-theme`, `editor-body-width`),
read on editor init and written on change through small accessors that tolerate an
unavailable or throwing `localStorage`. No cookie, and the server is not involved.
The width preference is applied as a `data-body-width` attribute the stylesheet
keys off (a `max-width` per preset, with "Full" also lifting the page's centred
max-width); the colour scheme and theme are applied as attributes likewise.

Consequences: a cookie would only earn its place if the server needed the value
at render time -- to emit the right markup server-side and avoid a first-paint
flash. But rendering is browser-owned and the no-JavaScript path is raw Markdown
(ADR-040), so these are pure client concerns; a cookie would add a server
round-trip and a contract for no benefit. The trade-off accepted is that the page
loads with defaults and the JS applies the stored preference (a brief flash is
possible), and that preferences are per-browser, not per-user-account (there is no
account model -- ADR-031). New view preferences follow the same one-key pattern.

Extends ADR-036 (editor visual themes) to the persistence question and applies it
to the width preference; consistent with ADR-040 (browser-owned rendering).

### ADR-045: Document-Tree Mode Serves And Edits A Filesystem Tree In Place

Status: Accepted.

Context: Beyond the flat single-document store (ADR-014), the editor needs to
serve and edit an existing MkDocs-style documentation tree on the filesystem:
nested section folders of `.md` pages, each with a peer `assets/` folder, and
page-relative image links (`![](assets/x.png)`). Read and write the real tree
directly (versioning is a later concern). The hard parts are document identity
for nested paths and -- the crux -- making a page's relative `assets/...` links
resolve to the real files without rewriting them.

Decision: add a tree mode, selected by a `document_tree_root` config key (the
flat store stays the default). The whole tree is reachable under `/documents/` as
resources whose URL mirrors their filesystem path: `GET /documents/<path>.md`
serves the raw Markdown, `POST /documents/<path>.md` saves it, and every other
tree file (images, attachments) is served statically and path-safely (reusing
`Static.resolveStaticPath`, ADR-030/034). The editor opens at the document's own
URL with a `?edit` flag (`/documents/<path>.md?edit`). The `?edit` view-selector
is what makes relative assets resolve for free: because the editor page lives at
the file's own path, the browser resolves `assets/x.png` to
`/documents/<dir>/assets/x.png` -- the real asset's static URL -- with no
`<base>` tag and no link rewriting. (A separate `/edit/...` prefix would move the
page's base path and break that.) The document id is the tree-relative path
including `.md`.

Consequences: this is the most resource-oriented shape -- documents and assets
each have a canonical URL that mirrors the tree, GET reads and POST writes, and
relative links resolve to the resources they name. It reuses the proven static
serving (zero-copy, path-safe) for everything but the edit page and save. The
router's terminal-only `*wildcard` makes a `/documents/<path>/edit` suffix
impractical, which the `?edit` query sidesteps (and which the relative-asset
resolution wants anyway). Writes go straight to the user's files; document
versioning and an undo/safety net are deferred and called out as follow-ups. The
flat mode and its routes are unchanged.

### ADR-046: Tree Uploads Land In The Page's Peer `assets/` With Meaningful Names

Status: Accepted.

Context: In tree mode (ADR-045) an upload must fit the tree's layout: the file
belongs in the editing page's peer `assets/` folder and is referenced
page-relative (`assets/<name>`), not in the central content-addressed store
(ADR-042) with an absolute `/attachments/<hash>/<name>` URL. The owner wanted
meaningful filenames with real extensions (the content hash hides the type) while
keeping the de-duplication the hashed store gave.

Decision: a tree upload is `POST /documents/<path>.md?asset` with the file as the
raw body and the original name in `X-Attachment-Filename`. The server writes it
into the document's peer `assets/` folder under a sanitised, meaningful filename
with its real extension, de-duplicating within that folder (identical bytes reuse
the existing file) and suffixing on a name clash with different content
(`diagram.png` -> `diagram-2.png`), gated by the same type allow-list as the
central store (415 otherwise). It returns `{"url":"assets/<name>"}`, a
page-relative reference the editor inserts. A `?asset` POST is dispatched to the
upload; a plain POST still saves the document.

Consequences: assets sit beside their page exactly as the tree expects, with
human-readable, typed filenames, and dedup is preserved -- now local to each
folder (cross-page duplication is inherent to the peer-assets layout and
accepted). Naming meaningfully (rather than by hash) needs collision handling,
which the within-folder suffix provides; the trade-off versus the central store's
collision-free hashing is intentional, scoped to tree mode. The flat mode keeps
the content-addressed `/attachments` store (ADR-042). Reuses the filename
sanitiser and allow-list from `MicroHttp.Attachment`.

### ADR-047: Frontmatter Is Preserved And Hidden From Editing

Status: Accepted.

Context: Tree documents carry YAML frontmatter (a `name`, sidecar `meta` paths, a
`cover-image`). The editor had no frontmatter handling: remark parsed a leading
`---...---` as a thematic break plus literal text, so it rendered wrong and would
be corrupted on save. The frontmatter is metadata the author should not edit, but
it must survive a round-trip verbatim.

Decision: split the frontmatter off the document on load (and on `setMarkdown`)
and stash it verbatim, so the editors only ever receive the body and the author
can neither see nor edit it (in any mode). Re-attach it unchanged when the
document is persisted, via a `documentMarkdown()` used for the form value
(`ElementInternals`) and the htmx autosave parameter; the editor's `toMarkdown()`
stays body-only, since it drives the preview, pane sync, and mode-switch
validation. A leading `---` with no closing delimiter is a thematic break, not
frontmatter.

Consequences: frontmatter round-trips byte-for-byte while the editing surface
shows only the body, and the body is re-serialised canonically as before. Hiding
it (rather than showing it read-only) is the simplest faithful option and what
the owner chose; a read-only display remains a later possibility. The split is at
the editor boundary, so it is editor-wide, not tree-specific. Consistent with
ADR-040 (browser-owned rendering): no server-side frontmatter handling is added.

### ADR-048: Raw HTML Is Preserved, Not Rejected, In The Trusted Tree Mode

Status: Accepted.

Context: ADR-040/041 uniformly reject raw HTML at save time, because the editor
served *untrusted, user-submitted* content (raw HTML = stored XSS). But the
document tree is the user's *own* first-party files, and ~half of them carry HTML
-- almost all of it export-metadata comments (`<!-- ... -->`), a few with visible
markup (MkDocs grid cards). The editor's strict parse throws on an `html` node, so
those documents could not be loaded or saved without error or loss. The trust
calculus that motivated the rejection does not hold for first-party files.

Decision: in tree mode only, preserve raw HTML rather than reject it. An opt-in
`raw-html` content extension carries each `html` node (block or inline) through
verbatim and renders it *inert* -- shown escaped, never as live HTML -- so editing
a document neither loses nor executes its HTML; the editor registers it only when
the server marks tree mode. Both editing surfaces preserve it: source mode is
verbatim text, and the visual editor pre-extracts raw-HTML spans (by remark source
position) into sentinels before its Markdown loader (marked) can interpret or drop
them, then re-inserts them as inert raw-html nodes after load. The tree save path
drops the raw-HTML guard (the files are trusted and nothing renders the HTML as
live). The flat mode is unchanged: it still rejects raw HTML, and its parse still
throws on an `html` node.

Consequences: first-party documents load, edit, and save -- in visual or source
mode -- without losing or executing their HTML, while the untrusted flat mode keeps
the ADR-040/041 trust boundary intact: the rejection moves from "always" to
"untrusted contexts only", matching the actual threat model. Nothing in the editor
renders raw HTML as live markup in either mode (it is inert when preserved), so no
execution surface is introduced. Refines ADR-040/041 (raw-HTML rejection is now
scoped to untrusted content); builds on ADR-041's content-extension registry.

### ADR-049: Sidecar Metadata Is Maintained By Minimal-Byte YAML Edits, Never Reserialised

Status: Accepted.

Context: A tree page (ADR-045) carries sidecar metadata in its meta directory
`<dir>/meta/<base>.meta/`: `attachments.yaml` and `images.yaml` list the page's
attachments and inline images, alongside an untouched `meta.yaml`. These files
were produced by a legacy CMS export and carry fields we do not reproduce for
new uploads (`id`, the original CMS `path`) with quoting and key order we do not
control. An upload (ADR-046) writes the asset file but did not record it in this
metadata, and an inline image's `short_title` should follow the body image's alt
text. Maintaining these files by parsing the whole list and reserialising it
would rewrite every untouched legacy entry in our emitter's style -- dropping or
reformatting `id`/`path`, key order, and quoting -- so a diff against the corpus
would light up entries we never meant to change. That is unacceptable for an
in-place write into the user's real files.

Decision: never reserialise a sidecar file. Maintain it with two minimal-byte
edits that touch only the bytes we own. (1) On upload (server-side in
`treeUpload`, reusing `inlineImageExtension` to pick the target file), append one
new entry block to the end -- or, when the file is the empty `[]`, replace that
with the single block. A new attachment entry carries `name` (the original
filename, single-quoted), `local_path` (`assets/<stored-name>`, already
URL-safe so unencoded), `extension`, and `external: false`; `id` and `path` are
omitted. A new image entry carries `local_path`, `short_title` (the filename at
creation), and `description: ''`. The append is idempotent and deduplicated by
`local_path` against the target file. (2) On save, the editor -- which already
parses the body and owns Markdown understanding (ADR-040) -- sends a
`[{local_path, short_title}]` payload alongside the document; the server
surgically replaces only the `short_title:` value line within each matched
`local_path` block in `images.yaml`, updating nothing else and writing nothing
when the value is unchanged. The "alt text else filename" rule stays editor-side.
The meta directory and a missing target file are created on demand; `meta.yaml`
and the sibling file are not. Attachments stay append-only -- `name` is never
synced from body link text.

Consequences: new uploads are recorded and inline-image `short_title` tracks the
edited alt text, while every untouched byte of these legacy files -- legacy
entries, `description`, key order, quoting -- stays identical, so a corpus diff
shows only the entries we added or the single values we changed. The cost is two
purpose-built, format-fragile editors (append a known-shape block; replace a
known key's value within a located block) instead of a general YAML reader and
writer; this is deliberate, since we only ever emit our own entry shape and edit
values we authored. The classification (images vs attachments) reuses the
existing `inlineImageExtension` so it is not duplicated across languages
(ADR-040). Reading these files for the metadata panel is sidecar-metadata access,
not Markdown rendering, so it does not cross the ADR-040 boundary. Concurrent
edits are out of scope (single-user local tool). Builds on ADR-045/046; consistent
with ADR-040 (Markdown understanding stays browser-owned) and ADR-047
(frontmatter is the in-page metadata; this is the out-of-page sidecar).

### ADR-050: Reading Is The Default; A Page GET Renders Read-Only, Raw Markdown Moves Behind ?raw

Status: Accepted (realised by RFC-0020).

Context: ADR-045 set the tree request model as a plain `GET /documents/<path>.md`
serving the raw Markdown and `?edit` opening the editor. Following a link to a
page therefore showed raw Markdown source, which is poor for reading. The owner
wants reading -- rendered -- to be the default browsing experience, to match the
editor's own rendering, and to carry the same side panels (RFC-0019, and later a
navigation tree and a table of contents) and the visual/Markdown/split view
switcher.

Decision: a plain `GET` on a tree Markdown page serves a read-only rendered view;
`?edit` serves the editable editor (unchanged); `?raw` serves the raw Markdown
verbatim as `text/markdown` (the former plain-`GET` behaviour, moved behind the
selector); `POST` still saves. The read view reuses the editor shell rather than a
second renderer: an opt-in `data-readonly` attribute (absent = editable, so flat
mode and `?edit` are unchanged) disables content editing and the server omits the
autosave form, so there is no write path. The top bar (presentation -- view
switcher, width, theme, document name) stays; the bottom bar (editing controls)
plus the floating editing affordances (bubble toolbar, slash menu, table/link
controls, upload) are hidden, and the attachments panel degrades to a read-only
list. Reading opens in visual mode (the view mode is not persisted and defaults to
visual); switching to Markdown/split while reading is session-only. A missing page
returns `404` for both `GET` and `?raw`; seeding a starter document stays an
`?edit`-only affordance.

Consequences: a plain `GET` of a page now returns an HTML page, not raw text --
a deliberate breaking change for tooling and diffs, which use `?raw`. Reading and
editing render identically per view because they are the same shell (parity is
"read mirrors edit within each mode", not "the visual and split renderers agree" --
that pre-existing divergence is untouched). Rendering stays browser-owned (no
server-side Markdown renderer), and a no-JavaScript `GET` degrades to the embedded
raw Markdown, so ADR-040 holds. Amends ADR-045's request model (`GET` reads
rendered; `?raw` is raw; `?edit` edits; `POST` saves); the document id and URL
scheme are otherwise unchanged. Builds on ADR-040 (browser-owned rendering),
ADR-047 (frontmatter hidden), and ADR-048 (raw HTML inert).

### ADR-051: Retire The Client Validation Gate; Round-Trip Stability By Offline Trust

Status: Accepted.

Context: The editor runs two Markdown engines. `marked` (via `@tiptap/markdown`)
is the display and editing engine for every surface a user sees -- the read
view, the visual view, and the split view's right pane. `remark` (the
content-extension registry) was retained by ADR-020 as "the reference parser and
validation fixture while Tiptap Markdown support settles", and ADR-040/ADR-041
kept a client save-time check that documents stay "within the editor's
round-trippable subset". In production that `remark` path survives only as a
validation gate: `renderMarkdown` is called in `switchMode` and
`updatePreviewFromMarkdown`, and its HTML output is discarded (the `preview`
slot it targets is never assigned -- there is no rendered-preview pane). The gate
therefore validates a third representation (`remark` mdast) whose acceptance
diverges from `marked`'s. When `remark` is stricter, it blocks documents
`marked` renders fine -- invisibly, because the parse-error banner lives in the
read view's hidden footer: an empty list item (`listItem:empty`) made the
Markdown and split views silently unreachable, and a rejected edit is shown on
screen but never recorded for save (the early return skips
`dispatchMarkdownChange`, so `setFormValue`/`markDirty` never fire).
Tiptap/`marked` has since become the de facto engine across read, visual, split,
and every shipped extension; the "while Tiptap settles" condition of ADR-020 has
elapsed.

Decision: (1) Name the saved-page contract **round-trip (reopen) stability**:
reopening a saved page shows the author what they last saw, measured through the
real `marked` + serialiser pipeline, not representability in any external grammar
(`CONTEXT.md`). (2) Retire the runtime validation gate -- no `remark` validation
in `switchMode` or on edit -- and remove the parse-error UI and the always-null
`preview` slot. Enforcement is **offline trust**: the per-extension golden
round-trip tests ADR-041 already designated as the correctness net. (3) Keep the
`remark` parse pipeline **test-only**, as the executable definition of the
supported subset and the serialiser's inverse-check (`parseMarkdown` then
`documentToMarkdown` is identity); this returns `remark` to ADR-020's
reference-fixture role with zero production runtime presence. (4) Delete the
model-to-HTML render half (`renderMarkdown`/`renderDocument` and each extension's
`renderBlock`/`renderInline`): it is production-dead and not part of the
markdown<->model spec, and its only plausible reuse -- a `remark`-rendered read
view -- would reintroduce the very divergence being removed. (5) Replace the
narrow parse-error surface with a general client-side **error boundary plus a
dismissible banner** (console logging) so unexpected failures surface instead of
failing silently; persistent server-side telemetry is deferred (RFC-0023).
Implemented by RFC-0022.

Consequences: the Markdown and split views are always reachable, and edits are
never silently dropped; production has one display engine (`marked`) plus
`remark`'s span-finders and the DOM-to-Markdown serialiser model. The supported
subset is no longer constrained at runtime by a second parser -- it is whatever
`marked` loads and the serialiser emits, with the golden tests pinning
markdown<->model. The change refines ADR-040/ADR-041: the client
"round-trippable subset" validation they retained is removed; the server's
raw-HTML rejection trust boundary (ADR-041) is unchanged, and rendering stays
browser-owned (ADR-019/ADR-040 hold). A residual risk is recorded honestly: the
one link that was never unit-tested -- `marked`'s real ProseMirror DOM into
`documentFromElements` -- stays manually verified in Chrome (happy-dom cannot
reproduce that DOM); offline trust does not close that gap, it stops the `remark`
gate from appearing to. Builds on ADR-019 (server stores/serves), ADR-020
(`remark` as reference fixture), and ADR-041 (golden tests as the net).

### ADR-052: The Server Accepts Client-Error Telemetry (A Bounded Exception To Store-And-Serve)

Status: Accepted.

Context: ADR-019 keeps the server minimal -- it stores and serves Markdown
documents and static assets, and does not process application events. The editor
gained a global error boundary (RFC-0022) that surfaces unexpected client
failures to the user as a banner, but once the tab closes there is no record an
operator can inspect: failures are invisible in aggregate. The blank-page class
of bug (e.g. the bare-image/callout crash) is exactly the kind that needs
after-the-fact visibility once the editor points at the live documentation tree
with real authors. Capturing that requires the server to receive something other
than a document.

Decision: add a single write-only telemetry endpoint, `POST /client-errors`, as
a deliberate, bounded exception to ADR-019. It accepts a small
form-urlencoded **client-error report** (message, bounded stack, page path,
kind), stamps it server-side (timestamp, peer, user-agent), escapes every value
logfmt-safely, and appends one line to a dedicated **client-error log**
(`client_error_log`), separate from the access log. It returns `204` and is
fire-and-forget. "Sentry-like" means the operational outcome -- queryable error
visibility -- not the Sentry protocol or any outbound integration; the server
gains no network egress and no new external dependency. The report carries no
page body content and no user identity (privacy). The endpoint is unauthenticated
and assumes a trusted/internal deployment, matching the editor's context; the
body is size-capped and the client de-duplicates and caps reports per session,
but there is no server-side per-IP rate limiting (the growth path -- an
`MVar` token bucket created at startup and shared via closure capture -- is
recorded but not built). The flat and tree modes both expose the route.

Consequences: the server now has exactly one endpoint that is neither a document
nor a static asset, and it writes application-supplied data to disk -- a real
departure from ADR-019, scoped to a single bounded, write-only, no-read endpoint
so the store-and-serve thesis otherwise holds. Operators gain a greppable
client-error log; the no-JavaScript reader produces none (telemetry is a client
concern). Refines ADR-019 (the exception) and builds on RFC-0022 (the boundary
that feeds it) and ADR-053 (the log it writes to rotates). The endpoint is
unauthenticated by design; if the deployment ever faces untrusted networks, the
recorded server-side rate-limiting path must be built. RFC-0023 implements this.

### ADR-053: Built-In Log Rotation By Size, Rename-Cascade Via Libc FFI

Status: Accepted.

Context: The server's logs (the access log, and now the client-error log of
ADR-052) are append-only files that grow without bound; an unauthenticated
telemetry endpoint makes unbounded growth a disk-fill concern. The natural fix is
rotation, but two runtime facts constrain it. MicroHs has no atomic `renameFile`
(noted in `MicroHttp.Attachment`), so the classic logrotate rename cannot use
`System.Directory`. And the current logger (`fileLogfmtLogger`) is stateless --
it opens the file per line in append mode -- while connections are `forkIO`'d, so
a rotate interleaved with concurrent appends would lose lines or write to a
rotated file.

Decision: add built-in rotation to the file logger, applied uniformly to both
logs. Trigger on **size**: when the active file exceeds `log_max_bytes`
(default 10 MB), rotate. Strategy is a **rename-cascade**: `x.log` -> `x.log.1`
-> ... -> `x.log.<log_keep>`, dropping the oldest (`log_keep` default 5).
Renaming, size measurement, and unlinking use **libc FFI** (`rename`, `stat`,
`unlink`), the project's established escape hatch for `System.Directory`/`Data.Time`
gaps (`MicroHttp.Log` already FFIs `localtime`/`strftime`). The check-rotate-append
sequence is serialised by a **per-file `MVar`** created at startup and captured by
the logger closure, so the logger becomes stateful (its constructor moves into
IO, threaded from `main`/`appFromConfig`); each log file has its own lock and
rotates independently.

Consequences: both logs are bounded to roughly `(log_keep + 1) x log_max_bytes`
on disk, with no external `logrotate` needed. The logger gains shared mutable
state and a small libc FFI surface; app construction gains an IO step to create
the locks. Rotation is best-effort-ordered under load but correct (no lost or
misfiled lines) because of the per-file lock; contention is negligible at the
expected volume. Builds on RFC-0012 (logging as middleware) and the
`MicroHttp.Log` FFI precedent; depended on by ADR-052. RFC-0024 implements this.

### ADR-054: Collapsibles Render As Native `<details>`/`<summary>` (The Element, Not The Source)

Status: Accepted.

Context: RFC-0017 renders a collapsible as a hand-rolled Tiptap node -- a `<div>`
with a `data-open` attribute and a click-to-toggle title bar -- explicitly to
avoid Tiptap's paid `Details` Pro extension. RFC-0017 separately rejected
`<details>` *as a source syntax* (authoring raw `<details>` HTML in the Markdown
would reopen the raw-HTML trust hole ADR-040 closed); collapsibles use the mkdocs
`???` syntax. Those two are distinct: the source decision did not govern the
rendered DOM element, and the `<div>` is incidental, not principled. `<details>`
/`<summary>` is the semantic disclosure element and brings native keyboard
toggling and screen-reader support for free.

Decision: render the collapsible node as
`<details class="markdown-collapsible markdown-collapsible-<kind>"><summary
class="markdown-collapsible-title" contenteditable="false">title</summary><div
class="markdown-collapsible-body">body</div></details>`. The open/closed state
stays in the ProseMirror document model (it round-trips to `???` versus `???+`
and must be undoable); the node view intercepts the `<summary>` toggle and routes
it through a transaction (as the `<div>` click handler already did), keeping the
`<details open>` attribute reflecting the model rather than letting the browser
mutate it directly. The Markdown source is unchanged -- still mkdocs `???`; the
editor *renders* `<details>` but never *accepts* raw `<details>` as input, so the
raw-HTML ban (ADR-040/041) and RFC-0017's source decision are untouched. The
DOM-serialise seam reads `<details.markdown-collapsible>` back to the model.

Consequences: collapsibles become semantic and accessible (native disclosure
marker, focusable summary, Enter/Space toggle, AT support), and the browser hides
the closed body natively so the custom open/close CSS is no longer needed. The
editor's DOM contract for a collapsible changes from `<div>` to `<details>`
(parse and serialise seams move together). Refines RFC-0017 (the rendered element
only); the `???` source syntax, the raw-HTML ban, and the no-Pro-dependency
constraint all stand. Implemented by RFC-0025.

### ADR-055: Theme Set Revision -- Retire Herbarium, Differentiate Studio And Workbench

Status: Accepted.

Context: ADR-036/RFC-0015 shipped the visual themes as a mostly-CSS axis: each
theme is a block of `--markdown-editor-*` token overrides, and the content
surface typography (`Georgia ... serif`) and page layout are shared by every
theme. In practice the colour-only themes read as near-identical -- Paper,
Herbarium, and Workbench differ only in palette plus minor chrome. Herbarium (a
ruled-paper journal) added a decorative background but no distinct interaction or
type, so it earned its keep the least. Studio (ADR-037) and Workbench were meant
to be structurally distinct (a Notion-style slash/bubble surface; an IDE
workbench) but both inherited the shared serif and most of the shared layout, so
neither resembled its source mockup
(`docs/mockups/markdown-editor-redesign-c-workspace-studio.html`,
`...-b-dark-workbench.html`).

Decision: (1) retire Herbarium entirely -- remove its token blocks, the ruled
background, and its entry from the three registration points (the CSS, the editor
dropdown, the server allowlist `knownEditorThemes`); a stored or configured
`herbarium` now falls back to Paper through the existing validation. (2) Let a
theme override the surface typography, not only colour: Studio switches the
content font to a sans-serif stack to match its Notion lineage, and gains a
caret placeholder hint ("Type / for commands") on empty blocks so the slash menu
is discoverable without a persistent toolbar. (3) Give Workbench the IDE layout
its mockup implies. The editor's shared DOM is regrouped so the document name is
a sibling of the presentation controls (not nested), and each region -- controls,
name, formatting bar, panes, status -- can be placed independently. Workbench
then makes the host a CSS grid forming a viewport-flush app frame: a presentation
rail down the left (view mode, width, theme, colour scheme -- the existing
controls stacked, a wider text rail, not the mockup's decorative icon strip), the
file tab and the formatting toolbar across the top, the panes filling the centre
(the only region that scrolls), and a full-width accent status bar along the
bottom carrying a format label, caret position, and word count. Content drops the
shared serif for a sans stack. The default themes keep the shared vertical-stack
layout unchanged (the grid is gated on the theme). The mockup's decorative
icon-only rail and caret-tracked preview are still excluded: the rail holds real
controls rather than feature-less icons, and caret-sync is feature work, not
styling.

Consequences: the theme set is Paper, Aurora, Blueprint, Workbench, Studio.
Typography and full layout join colour and bounded presets as themable axes: a
theme may now reflow the shared regions into a different frame (Workbench's IDE
grid) without forking the editor, because the regions are addressable DOM placed
by CSS per theme. The caret readout comes from the source pane (the only pane
with a line/column notion) and is hidden when no source pane is shown. Refines
ADR-036 and ADR-037 (the theme set and Studio's surfaces); the
registration-in-three-places contract and the pre-paint allowlist bootstrap
stand.

### ADR-056: The Table Of Contents Is Generated Client-Side From The Markdown

Status: Accepted.

Context: the editor sidebar gained a generated table of contents (a "Contents"
panel above the attachments panel). The headings could be extracted server-side
(at render/save) or client-side (in the editor). The Markdown body is already the
single client-side source of truth for every view mode (ADR-051: marked is the
engine, the server stores-and-serves and does not render); a server-extracted TOC
would need a render path the TestApp deliberately does not have, and would drift
from the live document as the author types.

Decision: generate the contents client-side. A pure `documentHeadings(markdown)`
scans the body for top-level ATX headings (skipping fenced code; setext and
indented headings are not listed) and the panel re-renders on every content
change, so it stays correct across the visual, source, split, and read views with
no server round-trip. The panel is shown whenever the document has at least one
heading (not only in the document tree), and sits in the right-hand sidebar above
the attachments panel; the sidebar collapses when it has nothing to show. Clicking
an entry scrolls the active pane to that heading -- the entry's index is the
heading's order in the document, matched to the n-th rendered heading element (or,
in source mode, the n-th heading line). Active-section highlighting (scrollspy) is
deferred.

Consequences: the TOC needs no server support and cannot drift from the live
document; it is one pure function plus a panel, unit-tested on the parser. The
index-based scroll target assumes the listed (top-level) headings map one-to-one
and in order onto the rendered headings, which holds for flat documents; headings
nested inside collapsibles or list items are intentionally neither listed nor
counted. Consistent with ADR-051 (rendering and document analysis are
browser-owned).

### ADR-057: The Page Title (Frontmatter `name`) Is Editable Above The Pane

Status: Accepted.

Context: a page's title is its frontmatter `name`, not part of the body content.
ADR-047 preserved frontmatter but hid it from editing entirely; there was no way
to change the title. The title is a primary, frequently-edited field and deserves
a first-class control, without exposing the rest of the frontmatter.

Decision: surface the `name` field as a dedicated title field above the editing
pane (sized to match it): an input in the edit view, read-only text in the read
view. Editing it does a minimal-byte update of the `name:` line in the preserved
frontmatter block (`setFrontmatterName`, mirroring ADR-049 for sidecar YAML) --
the value line is replaced (or a `name:` line inserted, or a frontmatter block
created when there is none) and every other line is kept verbatim. The change
flows through the normal save path, so the title persists with the body. The rest
of the frontmatter stays hidden and preserved.

Consequences: `name` becomes the one editable frontmatter field; the others remain
hidden and verbatim, so ADR-047's preservation guarantee still holds for them.
The read/write helpers (`frontmatterName`/`setFrontmatterName`) are pure and
unit-tested, including quoting of values that are not plain YAML scalars. Refines
ADR-047 (frontmatter is preserved -- and now its title is editable).

### ADR-058: Path Breadcrumbs Are Server-Built From Ancestor Index Titles

Status: Accepted.

Context: the editor showed the document filename in the top bar. A breadcrumb
trail of the path is more useful, but each crumb's label should be the ancestor
folder's *title* (its `index.md` frontmatter `name`), not the raw folder segment,
and each should link to that folder's page. Unlike the contents panel (ADR-056,
client-side from the open document), the ancestor titles live in *other* files the
client never loads -- only the server can read them.

Decision: build the trail server-side. For a document path the server walks its
ancestor folders, reads each `index.md`'s frontmatter title, and embeds the trail
as `data-breadcrumbs` JSON (`[{label, href}]`, href omitted for the current page)
on the editor element; the client renders it in place of the filename, each
ancestor a link and the current page plain text. A folder index page contributes
its folder as the current crumb rather than also linking it. Crumbs link to the
explicit `index.md` document (`/documents/<dir>/index.md`), because a bare
directory URL is not itself routable. A folder with no `index.md` title falls back
to a humanised segment (the root to "Cello"). The current page's own title comes
from the document already being served, so it costs no extra read.

Consequences: breadcrumbs need the server (a few `index.md` reads per page load,
bounded by tree depth) -- the opposite split from the contents panel, because the
data source is other files, not the open document. The pure parts (the linked
ancestor folders for a path; the frontmatter-title parser) are unit-tested; flat
(non-tree) documents get no trail and fall back to the filename. Reuses the
embed-JSON-then-render-client-side pattern of the attachments panel (RFC-0019).

## ADR Registry Open Review Items

- Verify socket layout assumptions on non-macOS platforms before treating
  Haskell-side sockaddr construction as portable.
- Resolved (2026-06-15, ADR-038): MicroHs `ByteString` is acceptable. The
  corruption fault is fixed in 0.16.3.0 (suite green;
  `docs/microhs-bytestring-bug-report.md`), and the RFC-0013 spike showed
  packing/append/coalescing perform well; the HTML renderer now builds on
  `ByteString`. Socket read/write throughput is still tracked by the socket
  benches.
- Port `sendfile` to Linux (different signature) and add `Range`/partial-content
  and conditional requests (`ETag`/`If-Modified-Since`) for file responses; the
  exact `Content-Length` from the file size is now in place (ADR-034, RFC-0014).
- Resolved (2026-06-16, ADR-040): the TestApp has no server-side Markdown
  renderer to remove; rendering stays browser-owned and no-JavaScript reading is
  raw Markdown. The save-time validation is retained as a trust-and-integrity
  guard, not a renderer.
