# Server Module Design

## Server Module Purpose

`MicroHttp.Server` owns the lifecycle of the HTTP server process. It connects the
socket adapter, HTTP parser, application function, and response serialiser.

## Server Module Responsibilities

- Create and close the listening socket.
- Accept client connections.
- Start one MicroHs green thread per accepted connection.
- Enforce the active handler cap.
- Read one request per connection for the first implementation.
- Convert parser failures into HTTP error responses.
- Call the application with a parsed request.
- Serialise and write the response.
- Close each client connection.

## Server Module Non-Responsibilities

- Raw socket FFI details.
- Route matching.
- HTML rendering.
- Filesystem state.
- TLS, compression, or static asset caching.

## Server Module Public Interface Sketch

```haskell
type Application = Request -> IO Response

data Settings = Settings
  { settingsHost :: Host
  , settingsPort :: Port
  , settingsBacklog :: Int
  , settingsMaxActiveHandlers :: Int
  , settingsMaxHeaderBytes :: Int
  , settingsMaxBodyBytes :: Int
  , settingsReadBufferBytes :: Int
  }

serve :: Settings -> Application -> IO ()
```

## Server Module First Behaviour

The first implementation should intentionally close every connection after one
request. It should always emit `Connection: close`.

Persistent connections can be added later only after parser and response
boundaries have explicit support for request framing and connection reuse.

## Server Module Test Strategy

Most server behaviour should be tested through injected socket-like operations
or through a small integration executable. Parser and response logic should stay
tested in pure modules.

Network integration tests are expected to be slower than parser/router/HTML unit
tests and should be separated in the build targets.
