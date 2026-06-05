# HTTP Response Module Design

## HTTP Response Module Purpose

`MicroHttp.Http.Response` serialises a `Response` into HTTP/1.1 bytes.

## HTTP Response Module Responsibilities

- Emit status line.
- Emit response headers.
- Compute and emit `Content-Length`.
- Emit `Connection: close`.
- Render response body bytes.
- Provide helpers for common response shapes.

## HTTP Response Module Non-Responsibilities

- Opening sockets.
- Writing bytes to sockets.
- Rendering HTML markup.
- Choosing application status codes.

## HTTP Response Module Public Interface Sketch

```haskell
serialiseResponse :: Response -> ResponseBytes

html :: Html -> Response
fragment :: Html -> Response
text :: Text -> Response
redirect :: Text -> Response
badRequest :: Text -> Response
notFound :: Response
methodNotAllowed :: Response
```

## HTTP Response Module Test Strategy

Response tests should be pure byte/string comparisons. They should assert
status, headers, computed length, blank line, and body.

Avoid broad snapshots once responses become large. Prefer focused assertions for
the HTTP framing contract.
