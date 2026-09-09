# Network Socket Module Design

## Network Socket Module Purpose

`MicroHttp.Network.Socket` is the MicroHs-specific adapter around socket FFI.
It replaces the missing `Network.Socket` dependency for this project.

## Network Socket Module Responsibilities

- Open a listening TCP socket on a host and port.
- Accept client sockets.
- Read strict `ByteString` chunks from a client socket.
- Write strict `ByteString` chunks to a client socket.
- Close sockets exactly once at the server boundary.
- Hide socket constants, sockaddr construction, and pointer types.
- Convert FFI failure return values into explicit `SocketError` values.

## Network Socket Module Non-Responsibilities

- HTTP parsing.
- HTTP response serialisation.
- Connection concurrency policy.
- TLS.
- HTTP/2.
- Filesystem or application state.

## Network Socket Module Public Interface Sketch

```haskell
module MicroHttp.Network.Socket
  ( ListenSocket
  , ClientSocket
  , Host(..)
  , Port(..)
  , SocketError(..)
  , listenTcp
  , accept
  , recv
  , sendAll
  , closeListenSocket
  , closeClientSocket
  ) where
```

```haskell
listenTcp :: Host -> Port -> Int -> IO (Either SocketError ListenSocket)
accept :: ListenSocket -> IO (Either SocketError ClientSocket)
recv :: ClientSocket -> Int -> IO (Either SocketError ByteString)
sendAll :: ClientSocket -> ByteString -> IO (Either SocketError ())
closeListenSocket :: ListenSocket -> IO (Either SocketError ())
closeClientSocket :: ClientSocket -> IO (Either SocketError ())
```

Every fallible public operation returns `Either`. The socket adapter should avoid
throwing exceptions for normal socket failures.

The public boundary uses strict `ByteString`. Text decoding, request parsing, and
HTML rendering belong above the socket layer.

## Network Socket Module MicroHs Findings

Spike 1 and Spike 2 proved:

- `socket`, `bind`, `listen`, `accept`, `recv`, `send`, `setsockopt`, and
  `close` are reachable through MicroHs FFI.
- `send` and `recv` must use concrete `CString` buffer types. A polymorphic
  `Ptr a` binding compiled but failed at runtime with `ERR: evalptr, bad tag K`.
- The sockaddr proof used a macOS `sockaddr_in` byte layout directly.

## Network Socket Module Decisions

- Keep `sockaddr_in` construction in Haskell first. C helper functions are a
  fallback, not the default path.
- Use strict `ByteString` for socket reads and writes.
- Return `IO (Either SocketError a)` for fallible socket operations.
- Do not introduce an external streaming library for the first server milestone.

These decisions and their rationale are recorded in the
[MicroHttp ADR Registry](../../adrs/index.md).

## Network Socket Module Streaming Position

Large response streaming should be supported by design, but the first production
socket module should not depend on an external streaming library.

The likely next step is a small local chunked response shape once strict
responses and filesystem file serving exist. That keeps large-file support
possible without committing the project to a streaming package before MicroHs
compatibility is proven.

Large request-body streaming is deferred. It needs parser limits, framing, and a
body-consumer API rather than only socket chunk reads.
