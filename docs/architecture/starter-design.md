# MicroHs HTTP Server Design

> This is the starter design, written before implementation and kept as the
> statement of original intent. Where it and the code disagree, the code and
> the [ADR register](../adrs/index.md) win. Known departures: htmx was
> retired in favour of plain fetch mutations (RFC-0036, ADR-0079), and the
> application boundary became a streaming iteratee (RFC-0004, RFC-0043).

## MicroHs HTTP Server Goal

Build a small HTTP/1.1 web server for MicroHs applications that can serve
server-rendered HTML, htmx fragments, and web-component markup without depending
on GHC-only web frameworks.

The server should optimise for a small, understandable runtime surface:

- HTTP/1.1 over plain TCP.
- One MicroHs green thread per accepted connection.
- Value-level routing for the initial implementation.
- HTML responses as the primary response type.
- Filesystem-backed state rather than a traditional database.
- Reverse-proxy integration for TLS, compression, request limits, and production
  edge concerns.

The initial server does not aim to be Warp, WAI, Servant, IHP, Snap, or Yesod.
It should be a practical MicroHs-native server with a deliberately narrow HTTP
contract.

## MicroHs HTTP Server Non-Goals

- No TLS implementation in MicroHs.
- No HTTP/2.
- No WebSocket support in the first version.
- No chunked request-body support in the first version.
- No persistent keep-alive requirement in the first version.
- No type-family-based routing.
- No Template Haskell or quasiquoted templates.
- No database dependency.
- No automatic JSON API framework.

## MicroHs HTTP Server Constraints

MicroHs has enough primitives to make a small HTTP server plausible:

- Low-level socket FFI hooks exist for `socket`, `bind`, `listen`, `accept`,
  `recv`, and `send`.
- `forkIO`, `MVar`, `Chan`, `QSem`, and `QSemN` are available.
- STM is available with `TVar`, `TMVar`, `TChan`, `TQueue`, and `TBQueue`.
- `catchSTM` is exported but currently not implemented, so designs must not rely
  on it.
- MicroHs supports type-level `Symbol` and `Nat`, `KnownSymbol`, kind
  signatures, type operators, GADTs, type equality constraints, functional
  dependencies, and explicit type application.
- General type families should be treated as unavailable for this project.

MicroHs package compatibility is not the same as GHC package compatibility.
Several modules that are separate GHC packages are present inside MicroHs
`base`, and many Hackage packages require `base >= 4.x && < 5`. Any external
package must be checked with `mcabal` or a focused compilation spike before it
is accepted into the design.

## MicroHs HTTP Server Architecture

The application boundary should be simple:

```haskell
type Application = Request -> IO Response

data Request = Request
  { requestMethod  :: Method
  , requestPath    :: [Text]
  , requestQuery   :: [(Text, Text)]
  , requestHeaders :: Headers
  , requestBody    :: ByteString
  , requestRawPath :: ByteString
  }

data Response = Response
  { responseStatus  :: Status
  , responseHeaders :: Headers
  , responseBody    :: Body
  }

data Body
  = Strict ByteString
  | Builder Builder
  | File FilePath
```

The server stack should be split into independent layers:

- Socket accept loop.
- Connection read/write layer.
- HTTP request parser.
- Response serialiser.
- Router.
- HTML rendering helpers.
- Filesystem state store.
- Middleware.

Each layer should have tests that can run without opening a socket where
practical.

## MicroHs Socket Server Layer

The socket layer owns listening and connection lifecycle:

```haskell
serve :: Settings -> Application -> IO ()
serve settings app = do
  sock <- listenOn settings
  forever $ do
    client <- accept sock
    forkIO $ handleClient settings app client
```

The first implementation should close each connection after one request. It
should set `Connection: close` in responses and delegate connection reuse to a
reverse proxy.

The first implementation should include a concurrency cap:

```haskell
data Settings = Settings
  { settingsPort              :: Int
  , settingsHost              :: Host
  , settingsMaxConnections    :: Int
  , settingsMaxHeaderBytes    :: Int
  , settingsMaxBodyBytes      :: Int
  , settingsReadBufferBytes   :: Int
  }
```

`QSem` or `QSemN` is enough for a simple cap. A `TBQueue` can be considered if
accepted connections should be queued before workers handle them.

## MicroHs HTTP Parser Layer

The first parser should implement only the subset needed by htmx forms and
normal browser navigation:

- `GET`, `POST`, `PUT`, `PATCH`, and `DELETE`.
- HTTP/1.0 and HTTP/1.1 request lines.
- Headers as raw byte strings or decoded text after validation.
- Request bodies with `Content-Length`.
- Query string parsing.
- URL path splitting and percent-decoding.

The first parser should reject:

- Chunked request bodies.
- Invalid request lines.
- Header blocks over the configured limit.
- Bodies over the configured limit.
- Unsupported transfer encodings.

Parser errors should map to explicit responses:

```haskell
data ParseError
  = BadRequest
  | HeaderTooLarge
  | BodyTooLarge
  | UnsupportedTransferEncoding
  | UnsupportedHttpVersion
```

The parser should be tested with byte strings rather than sockets.

## MicroHs Response Serialisation Layer

Responses should always emit:

- Status line.
- `Content-Type` where applicable.
- `Content-Length`.
- `Connection: close`.

Response helpers should cover the common cases:

```haskell
html :: Html -> Response
fragment :: Html -> Response
text :: Text -> Response
redirect :: Text -> Response
notFound :: Response
badRequest :: Text -> Response
```

File responses can be added after the basic response path is stable. Static
asset serving is useful for local development, but production can put Caddy or
nginx in front of a static directory.

## MicroHs Routing Layer

The first router should be value-level:

```haskell
data Route = Route Method Pattern Handler

type Handler = Request -> IO Response

data Pattern
  = Exact [Text]
  | WithParams [PathPart]

data PathPart
  = Lit Text
  | Capture Text
```

Example route table:

```haskell
app :: Application
app = route
  [ get "/" home
  , get "/todos" todosIndex
  , post "/todos" todosCreate
  , delete "/todos/:id" todosDelete
  ]
```

This should keep routing easy to debug while the server foundation is still
being proved.

## MicroHs Typed Routing Spike

A constrained type-level router is worth a separate spike after the value-level
router works.

The spike should avoid type families and use functional dependencies or plain
type classes instead:

```haskell
data GET
data POST

data End method
data Lit (segment :: Symbol) next
data Capture (name :: Symbol) value next

class RouteSpec spec handler | spec -> handler where
  routeSpec :: Proxy spec -> handler -> Route
```

Candidate route type:

```haskell
type TodoShow =
  Lit "todos" (Capture "id" TodoId (End GET))

todoShow :: TodoId -> Request -> IO Response
todoShow todoId req = ...
```

The spike should answer these questions:

- Can MicroHs accept recursive `RouteSpec` instances with functional
  dependencies?
- Can `KnownSymbol` recover path segment names ergonomically?
- Can captures be parsed with a simple `FromPathPiece` class?
- Are error messages usable enough for application authors?
- Does this require `UndecidableInstances`-style behaviour that MicroHs does not
  handle well?

Typed routing should not block the initial server. The value-level router should
remain available even if the typed routing spike fails.

## MicroHs HTML Rendering Options

The design should prefer arbitrary modern HTML attributes and custom elements
over strict XHTML purity.

Existing candidates:

- `xhtml`: Listed in the MicroHs known-package install list. It is an XHTML
  combinator library and is the most plausible existing package.
- `lucid`: Attractive API, but it requires a package compatibility spike.
  Current metadata is extension-light, but it depends on the normal Hackage
  package shape around `base`, `mtl`, and `blaze-builder`.
- `blaze-html`: Less promising without porting more of the Blaze stack. A local
  `old/blaze-builder-mhs` exists, but it is a minimal builder replacement, not
  `blaze-html`.

The recommended first implementation is a tiny local pure monadic HTML builder.
The monad should be a writer-style accumulator over a byte-string builder, not
`IO`. This gives templates `do` notation while keeping rendering deterministic
and easy to test.

```haskell
newtype HtmlM a = HtmlM (a, Builder)

type Html = HtmlM ()

renderHtml :: Html -> Builder

text :: Text -> Html
rawTrusted :: Builder -> Html

el :: Text -> [(Text, Text)] -> Html -> Html
voidEl :: Text -> [(Text, Text)] -> Html

attr :: Text -> Text -> (Text, Text)
hxPost :: Text -> (Text, Text)
hxTarget :: Text -> (Text, Text)
hxSwap :: Text -> (Text, Text)

custom :: Text -> [(Text, Text)] -> Html -> Html
```

`rawTrusted` should be visibly dangerous and reserved for already-trusted
markup. Normal text nodes and all attribute values should be escaped by default.

The local builder should include escaping tests for text nodes and attributes. It
should make htmx and web-component markup straightforward:

```haskell
todoItem :: Todo -> Html
todoItem todo =
  custom "todo-item"
    [ attr "data-id" (todoIdText todo)
    , hxTarget "#todos"
    ] $ do
    div_ [class_ "todo-title"] $
      text (todoTitle todo)
    button_
      [ hxDelete ("/todos/" <> todoIdText todo)
      , hxTarget "#todos"
      ]
      (text "Delete")
```

The builder should not enforce a closed HTML element vocabulary. It should allow
custom elements and arbitrary attributes because htmx and web components rely on
names such as `hx-post`, `hx-target`, and `todo-item`.

## MicroHs Filesystem State Store

Initial application state should be filesystem-backed with an in-memory index.

```haskell
data Env = Env
  { storeRoot :: FilePath
  , appState  :: TVar AppState
  , writeQ    :: TQueue WriteJob
  }
```

The server should load state from disk on startup:

```haskell
loadState :: FilePath -> IO AppState
```

Handlers should read from `appState` and enqueue filesystem mutations:

```haskell
data WriteJob
  = PutDocument DocumentId ByteString
  | DeleteDocument DocumentId
  | ReplaceIndex AppState
```

A single writer thread should serialise writes:

```haskell
writerLoop :: Env -> IO ()
writerLoop env = forever $ do
  job <- atomically (readTQueue (writeQ env))
  applyWriteJob env job
```

Filesystem writes should use an atomic-write discipline:

- Write to a temporary file in the same directory.
- Flush the file handle where MicroHs support allows.
- Rename the temporary file into place.
- Update the in-memory index only after the write succeeds, or record an
  explicit pending-write state if handlers update memory before disk.

The first implementation should prefer simple consistency over throughput.

## MicroHs Middleware Layer

Middleware should be ordinary function composition:

```haskell
type Middleware = Application -> Application

withLogging :: Middleware
withMaxBodySize :: Int -> Middleware
withMethodOverride :: Middleware
withHtmxHeaders :: Middleware
```

Useful htmx helpers:

- Detect `HX-Request`.
- Emit `HX-Redirect`.
- Emit `HX-Trigger`.
- Return fragments instead of full layouts when appropriate.

Method override is useful for browser forms:

```text
POST /todos/123
_method=DELETE
```

## MicroHs Reverse Proxy Boundary

Production deployments should put a reverse proxy (nginx or similar) in front
of the MicroHs server. The following edge concerns are the proxy's
responsibility and are **deliberately not built into MicroHttp** -- the server
assumes a proxy fronts it in production:

- **TLS** -- termination and certificates.
- **HTTP/2 and HTTP/3** -- the upstream link stays HTTP/1.1.
- **Client keep-alive** (persistent connections) -- nginx keeps client
  connections alive by default, and its default upstream mode is a new
  connection per request, which matches our `Connection: close` per response
  (RFC-0012 non-goal).
- **Body compression** (gzip, brotli) -- MicroHttp never compresses a response
  body in process. This is also why a `sendfile` `FileBody` being opaque to
  `egress` transforms (RFC-0014) costs nothing: we would not compress it here
  anyway.
- **Static asset caching** and CDN edge.
- **Request rate limiting** and per-IP connection caps.
- **Slow-client / connection-flood protection** (slow-loris) -- see below.
- **Access logs** at the edge, if the operator prefers them there.

A proxy is the right answer for **slow-loris** and similar slow-client attacks:
nginx bounds how long it waits for headers and bodies
(`client_header_timeout`, `client_body_timeout`), caps connections per client
(`limit_conn`), and absorbs many idle connections cheaply on its event loop, so
only complete requests reach the upstream. MicroHttp keeps a lightweight
backstop for proxy-less deployments -- the idle read and write timeouts
(RFC-0006, RFC-0008) bound a single stalled connection and
`settingsMaxActiveHandlers` caps concurrency -- but it deliberately does not
build the fuller edge protection (per-IP limits, connection-rate caps), which
is the proxy's job.

Keep-alive is worth calling out specifically: the proxied path gives clients
persistent connections with no persistent-connection code in the MicroHs
server. Our own keep-alive would matter only for proxy-less deployments or to
pool proxy-to-upstream connections under high load.

The MicroHs server should own:

- Application routing.
- HTML and fragment rendering.
- Form handling.
- Filesystem state.
- Application-level logging.

Static asset serving and access logging now exist in-process (RFC-0010,
RFC-0009), so the server stands alone without a proxy for local development
and proxy-less deployments. These complement rather than replace the boundary:
a reverse proxy can still shadow the static route and take over access logging,
TLS, and compression in production. Static serving streams close-delimited
(no `Content-Length` or keep-alive yet), so a caching proxy in front is the
production answer until the file-size FFI lands.

## MicroHs Implementation Plan

### MicroHs Spike Results

- Spike 1 reached the exit criterion on macOS: a MicroHs-compiled executable
  listened on `127.0.0.1:8080`, accepted one `curl` request, read 77 request
  bytes, sent a fixed HTTP/1.1 response, and exited cleanly.
- The socket `send` and `recv` FFI bindings must use concrete `CString` buffer
  types. A polymorphic `Ptr a` binding compiled but failed at runtime with
  `ERR: evalptr, bad tag K`.
- The current sockaddr construction is a macOS-focused proof using the
  `sockaddr_in` byte layout directly. A portable socket module should replace
  that with C helper functions or verified per-platform layout handling.
- Spike 2 reached the concurrent accept-loop exit criterion on macOS: a
  MicroHs-compiled executable accepted six connections, forked each handler,
  capped active handlers at two with `QSem`, completed six concurrent `curl`
  requests, and stopped cleanly after all handlers finished.
- Spike 2 also handled an early-disconnecting client: the handler read `0`
  bytes, completed, and the remaining normal clients still received responses.
- Spike 3 reached the parser exit criterion for the first HTTP subset: request
  line parsing, headers, query parsing, `Content-Length` body extraction,
  oversized-header rejection, oversized-body rejection, and unsupported
  transfer-encoding rejection all compile and pass under MicroHs.
- Spike 4 reached the response serialiser exit criterion: status line, explicit
  headers, computed `Content-Length`, `Connection: close`, and body output are
  generated deterministically.
- Spike 5 reached the HTML builder exit criterion: a pure monadic builder
  renders custom elements, htmx attributes, escaped text, and escaped attribute
  values under MicroHs.
- Spike 6 reached the filesystem-store exit criterion: startup load, queued
  writes through `TQueue`, a single writer thread, overwrite, delete, in-memory
  state update, and reload from disk all work under MicroHs. The store uses a
  small `rename` FFI binding because MicroHs does not currently expose
  `renameFile`.
- Spike 7 reached the value-router exit criterion: literal routes, capture
  routes, method dispatch, 404, and 405 behaviour all work under MicroHs.
- Spike 8 reached the typed-router spike criterion: MicroHs accepts a
  fundep-based typed route prototype using `KnownSymbol`, typed captures, and a
  structurally computed handler type without type families.
- Spike 9 selected the local pure monadic HTML builder for the first
  implementation. `xhtml` and `lucid` remain package-port checks rather than
  first-slice dependencies; they were not available in the active MicroHs package
  path during this run.

### MicroHs Server Spike 1: Socket Echo

- Build a minimal TCP listener using MicroHs socket FFI.
- Accept one connection and send a fixed byte string.
- Verify `recv` and `send` behaviour on macOS.
- Verify failure and close behaviour.
- Capture any required socket constants or sockaddr helpers.

Exit criterion: `curl localhost:<port>` receives a fixed response from a
MicroHs-compiled executable.

### MicroHs Server Spike 2: Concurrent Accept Loop

- Add `forkIO` per accepted connection.
- Add a `QSem` or `QSemN` connection cap.
- Run concurrent `curl` requests.
- Verify failed clients do not block the accept loop.

Exit criterion: Multiple concurrent requests complete, and the server remains
responsive after client disconnects.

### MicroHs Server Spike 3: HTTP Request Parser

- Implement request-line parsing.
- Implement header parsing with a byte limit.
- Implement `Content-Length` body reads.
- Implement parse-error responses.
- Add parser tests using byte strings.

Exit criterion: Parser accepts common browser and htmx requests and rejects
malformed or oversized inputs deterministically.

### MicroHs Server Spike 4: Response Serialiser

- Implement status lines.
- Implement response headers.
- Implement `Content-Length`.
- Implement `Connection: close`.
- Add tests for serialised response bytes.

Exit criterion: Fixed `GET` and `POST` handlers work with `curl`.

### MicroHs Server Spike 5: HTML Builder

- Implement the tiny local HTML builder.
- Add escaping tests for text nodes and attributes.
- Add helpers for htmx attributes and custom elements.
- Render a full page and a fragment.

Exit criterion: htmx-compatible fragments can be returned without raw string
concatenation in handlers.

### MicroHs Server Spike 6: Filesystem Store

- Define a small document format for the first app state.
- Load state from a directory on startup.
- Implement a single writer thread with `TQueue`.
- Implement same-directory temp write and rename.
- Add crash-safety and partial-write tests where practical.

Exit criterion: State survives process restart and writes are serialised.

### MicroHs Server Spike 7: Value-Level Router

- Implement literal path matching.
- Implement capture path matching.
- Implement method dispatch.
- Implement 404 and 405 behaviour.
- Add tests for route selection and capture decoding.

Exit criterion: A small todo-style app can route index, create, update, and
delete actions.

### MicroHs Server Spike 8: Typed Router

- Implement the fundep-based typed route prototype.
- Test `KnownSymbol` path segments.
- Test typed captures with `FromPathPiece`.
- Compare ergonomics and errors with the value-level router.

Exit criterion: Decide whether typed routing belongs in the first release, in a
later module, or not at all.

### MicroHs Server Spike 9: Package Rendering Alternatives

- Try `xhtml` with htmx attributes and custom elements.
- Try compiling `lucid` or a reduced lucid-style subset with MicroHs.
- Decide whether to keep the local builder, wrap `xhtml`, or port another
  combinator library.

Exit criterion: Rendering approach is selected with evidence from MicroHs
compilation and handler ergonomics.

## MicroHs First Milestone

The first milestone should be a tiny local web app:

- `GET /` renders a full page.
- `GET /items` renders an item list.
- `POST /items` writes a filesystem-backed item and returns an htmx fragment.
- `DELETE /items/:id` removes an item and returns an htmx fragment or empty
  response.
- State survives restart.
- The app runs behind Caddy or nginx in local development.

This milestone proves the server, rendering, htmx, concurrency, and filesystem
state model without committing to a heavyweight framework shape.
