# HTTP Response Module Design

## HTTP Response Module Purpose

`MicroHttp.Http.Response` serialises a `Response` into HTTP/1.1 bytes.

## HTTP Response Module Responsibilities

- Emit status line.
- Emit response headers.
- Compute and emit `Content-Length` for strict bodies.
- Emit `Connection: close`.
- Render strict response body bytes.
- Write file response bodies in chunks.
- Provide helpers for common response shapes.

## HTTP Response Module Non-Responsibilities

- Opening sockets.
- Rendering HTML markup.
- Choosing application status codes.
- Static asset path resolution or access control.

## HTTP Response Module Public Interface Sketch

```haskell
serialiseResponse :: Response -> ResponseBytes
writeResponse :: ResponseWriter -> Response -> IO (Either ResponseWriteError ())

html :: Html -> Response
fragment :: Html -> Response
text :: Text -> Response
file :: FilePath -> Response
redirect :: Text -> Response
badRequest :: Text -> Response
notFound :: Response
methodNotAllowed :: Response
```

`serialiseResponse` is only valid for strict response bodies. File response
bodies need `writeResponse`, because they require opening a file and writing
chunks to the client.

The first file response implementation may omit `Content-Length` for files and
rely on `Connection: close`. Adding a file-size capability can make file response
headers more complete later.

## HTTP Response Module Test Strategy

Response tests should be pure byte/string comparisons. They should assert
status, headers, computed length, blank line, and body.

Avoid broad snapshots once responses become large. Prefer focused assertions for
the HTTP framing contract.

File response tests should use a temporary file and an injected writer so they do
not need to open a real socket.
