# MicroHttp Module Design Index

## MicroHttp Decision Register

Architectural decisions and rationale are recorded in the
[MicroHttp Design Decision Register](decision-register.md). Module documents may
describe local consequences, but new design decisions should be added to the
register.

## MicroHttp Module Boundary Decision

The implementation should use small public modules with clear ownership rather
than one large `MicroHttp` module. The public surface should be organised around
stable concepts:

| Module area | Primary responsibility | Design document |
| :--- | :--- | :--- |
| `MicroHttp` | Public facade and re-exports | [Public Facade Module Design](modules/public-facade.md) |
| `MicroHttp.Network.Socket` | MicroHs socket FFI adapter | [Network Socket Module Design](modules/network-socket.md) |
| `MicroHttp.Server` | Accept loop and connection lifecycle | [Server Module Design](modules/server.md) |
| `MicroHttp.Http` | HTTP request, response, status, and header types | [HTTP Types Module Design](modules/http-types.md) |
| `MicroHttp.Http.Parser` | HTTP/1 request parsing | [HTTP Parser Module Design](modules/http-parser.md) |
| `MicroHttp.Http.Response` | HTTP response serialisation | [HTTP Response Module Design](modules/http-response.md) |
| `MicroHttp.Router` | Value-level routing | [Router Module Design](modules/router.md) |
| `MicroHttp.Router.Typed` | Optional typed route builder | [Typed Router Module Design](modules/typed-router.md) |
| `MicroHttp.Html` | Pure monadic HTML rendering | [HTML Module Design](modules/html.md) |
| `MicroHttp.Store.FileSystem` | Filesystem-backed state adapter | [Filesystem Store Module Design](modules/filesystem-store.md) |
| `MicroHttp.Middleware` | Application transformations | [Middleware Module Design](modules/middleware.md) |

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
     -> MicroHttp.Http.Parser
     -> MicroHttp.Http.Response
  -> MicroHttp.Router
  -> MicroHttp.Html
  -> MicroHttp.Middleware
  -> MicroHttp.Store.FileSystem
```

Pure modules must not import socket or filesystem modules. In particular:

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
