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

Status: Proposed.

Context: Request handling after RFC-0003 is correct but strict: memory is
proportional to message size, and response bodies other than files are
strict values. The project wants constant-memory streaming on both sides
without an external streaming library (ADR-010) and without producer
pushback: the design discussion settled on the iteratee model, where
residual input lives in the consumer's result and flows forward through
monadic bind, enumerators own resource acquisition and release, and
enumerators return the consumer's final state, which a future keep-alive
loop needs.

Decision: Implement a local iteratee core (`Stream`, `Iter`, `Enumerator`,
concrete `ByteString` and `IO`). Producers are enumerators (socket, file,
strict value), consumers are iteratees (framing, handlers, the socket
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
instance can feed residue eagerly; the failure vocabulary (`IterError`)
covers both read and write transport failures, retiring RFC-0003's
`FrameError`. The pure parser shrinks to header bytes only. The
`Application` and router payload types change, and TestApp handlers
migrate. Unconsumed body bytes are disposed of by the server's
close-per-connection policy until keep-alive is revisited.

## ADR Registry Open Review Items

- Verify socket layout assumptions on non-macOS platforms before treating
  Haskell-side sockaddr construction as portable.
- Confirm whether MicroHs `ByteString` performance and allocation behaviour are
  acceptable for socket reads and writes under load.
- Decide whether file responses need a local file-size FFI before static asset
  support is considered production-ready.
- Decide how much of the TestApp Markdown renderer should be removed once editor
  preview/rendering is fully browser-owned.
