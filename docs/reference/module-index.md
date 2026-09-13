# MicroHttp Module Design Index

## MicroHttp Module Design Document Status

The per-module documents under `docs/architecture/initial-module-design/` are the starter
design, kept as a historical artifact. They record the contracts as designed
before implementation and are not updated as the code evolves. Current
decisions live in the [ADR Registry](../adrs/index.md); current and
planned cross-module designs live under `docs/design/` and `docs/rfcs/`. Read
the initial module documents for original intent, not as a description of
today's code.

## MicroHttp ADR Registry

Architectural decisions and rationale are recorded in the
[MicroHttp ADR Registry](../adrs/index.md). Module documents may describe
local consequences, but new design decisions should be added to the registry.

## MicroHttp Module Boundary Decision

The implementation should use small public modules with clear ownership rather
than one large `MicroHttp` module. The public surface should be organised around
stable concepts:

| Module area | Primary responsibility | Design document |
| :--- | :--- | :--- |
| `MicroHttp` | Public facade and re-exports | [Public Facade Module Design](../architecture/initial-module-design/public-facade.md) |
| `MicroHttp.Network.Socket` | MicroHs socket FFI adapter | [Network Socket Module Design](../architecture/initial-module-design/network-socket.md) |
| `MicroHttp.Server` | Accept loop and connection lifecycle | [Server Module Design](../architecture/initial-module-design/server.md) |
| `MicroHttp.Http` | HTTP request head, response, status, and header types | [HTTP Types Module Design](../architecture/initial-module-design/http-types.md) |
| `MicroHttp.Http.Parse` | Parser error and limit types (RFC-0004) | [RFC-0004](../rfcs/implemented/rfc-0004-iteratee-streaming-io.md) |
| `MicroHttp.Http.Parser` | HTTP/1 request-head parsing | [HTTP Parser Module Design](../architecture/initial-module-design/http-parser.md) |
| `MicroHttp.Http.PercentEncoding` | Shared path/form percent-decoding | [HTTP Parser Module Design](../architecture/initial-module-design/http-parser.md) |
| `MicroHttp.Http.Framing` | Incremental header framing iteratee (RFC-0004) | [RFC-0004](../rfcs/implemented/rfc-0004-iteratee-streaming-io.md) |
| `MicroHttp.Http.Response` | HTTP response serialisation and writing | [HTTP Response Module Design](../architecture/initial-module-design/http-response.md) |
| `MicroHttp.Iteratee` | General iteratee/enumerator streaming core (RFC-0004) | [RFC-0004](../rfcs/implemented/rfc-0004-iteratee-streaming-io.md) |
| `MicroHttp.Stream` | Stream error vocabulary, socket/file producers, and the block-streaming file folds, scans, writers and comparisons (RFC-0004, RFC-0040) | [RFC-0004](../rfcs/implemented/rfc-0004-iteratee-streaming-io.md), [ADR-0091](../adrs/adr-0091-io-is-block-streaming-by-default.md) |
| `MicroHttp.Bytes` | Index-loop `ByteString` scans that never unpack (RFC-0040) | [ADR-0088](../adrs/adr-0088-request-bodies-bound-for-files-never-enter-the-heap.md) |
| `MicroHttp.Form` | Streaming form consumer: parts routed by name to sinks, block-wise decoding (RFC-0042) | [ADR-0092](../adrs/adr-0092-form-bodies-are-routed-part-streams.md) |
| `MicroHttp.FileSystem` | Direct filesystem calls: stat, unlink, rename, temp paths | [RFC-0027](../rfcs/implemented/rfc-0027-in-server-move-and-delete.md) |
| `MicroHttp.Process` | Subprocess spawn with captures read or left on disk | [ADR-0090](../adrs/adr-0090-subprocess-capture-stays-on-disk.md) |
| `MicroHttp.Router` | Value-level routing | [Router Module Design](../architecture/initial-module-design/router.md) |
| `MicroHttp.Router.Typed` | Optional typed route builder | [Typed Router Module Design](../architecture/initial-module-design/typed-router.md) |
| `MicroHttp.Html` | Pure monadic HTML rendering | [HTML Module Design](../architecture/initial-module-design/html.md) |
| `MicroHttp.Store.FileSystem` | Filesystem-backed state adapter | [Filesystem Store Module Design](../architecture/initial-module-design/filesystem-store.md) |
| `MicroHttp.Middleware` | Application transformations | [Middleware Module Design](../architecture/initial-module-design/middleware.md) |

## MicroHttp Network Module Decision

Create `MicroHttp.Network.Socket`, not a top-level `Network` module.

The project needs a network module because MicroHs does not currently provide
`Network.Socket`. The module should hide raw FFI details, pointer layouts, socket
constants, and close/error handling from the server layer.

The module should not be named `Network` or `Network.Socket` in this project.
Using `MicroHttp.Network.Socket` avoids pretending to be the Hackage `network`
package and avoids future import ambiguity if MicroHs later gains a compatible
`Network.Socket`.

## MicroHttp Dependency Direction

Dependencies should flow inward from effects to pure logic:

```text
MicroHttp
  -> MicroHttp.Server
     -> MicroHttp.Network.Socket
     -> MicroHttp.Http.Framing
     -> MicroHttp.Http.Parser
     -> MicroHttp.Http.Response
  -> MicroHttp.Router
  -> MicroHttp.Html
  -> MicroHttp.Middleware
  -> MicroHttp.Store.FileSystem

MicroHttp.Http
  -> MicroHttp.Iteratee            (response body enumerator type)
  -> MicroHttp.Stream
       -> MicroHttp.Iteratee
       -> MicroHttp.Network.Socket
       -> MicroHttp.Http.Parse
```

The iteratee core (`MicroHttp.Iteratee`) is domain-free: it imports neither
the socket adapter nor any HTTP module. `MicroHttp.Http.Parse` holds the
parser error and limit types separately so the stream error vocabulary and
the HTTP types can both depend on it without an import cycle (RFC-0004).

Pure modules must not import socket or filesystem modules. In particular:

- `MicroHttp.Iteratee` must not import `MicroHttp.Network.Socket` or any
  HTTP module.
- `MicroHttp.Http.Parser` must not import `MicroHttp.Network.Socket`.
- `MicroHttp.Router` must not import `MicroHttp.Server`.
- `MicroHttp.Html` must not import any effectful module.
- `MicroHttp.Store.FileSystem` should not import `MicroHttp.Server`.

## MicroHttp First Implementation Scope

The first implementation should build these modules first:

- `MicroHttp.Network.Socket`
- `MicroHttp.Http`
- `MicroHttp.Http.Parser`
- `MicroHttp.Http.Response`
- `MicroHttp.Server`
- `MicroHttp.Router`
- `MicroHttp.Html`

`MicroHttp.Store.FileSystem`, `MicroHttp.Middleware`, and
`MicroHttp.Router.Typed` can follow once the server can run a small HTML app.
