# HTTP Parser Module Design

## HTTP Parser Module Purpose

`MicroHttp.Http.Parser` converts one buffered HTTP/1 request into a `Request` or
a precise parse error.

## HTTP Parser Module Responsibilities

- Parse request line.
- Parse headers.
- Enforce maximum header bytes.
- Enforce maximum body bytes.
- Read `Content-Length` request bodies.
- Reject unsupported transfer encodings.
- Split path and query string.
- Percent-decode path and query components.

## HTTP Parser Module Non-Responsibilities

- Reading from sockets.
- Retrying partial socket reads.
- Route matching.
- Response serialisation.

## HTTP Parser Module Public Interface Sketch

```haskell
data ParseLimits = ParseLimits
  { maxHeaderBytes :: Int
  , maxBodyBytes :: Int
  }

data ParseError
  = BadRequest String
  | HeaderTooLarge
  | BodyTooLarge
  | UnsupportedTransferEncoding
  | UnsupportedHttpVersion

parseRequest :: ParseLimits -> RequestBytes -> Either ParseError Request
```

## HTTP Parser Module Test Strategy

Parser tests should be pure fixture tests. They should cover:

- Valid `GET`.
- Valid form `POST`.
- Query parsing.
- Header normalisation.
- Header limit.
- Body limit.
- Unsupported transfer encoding.
- Unsupported HTTP version.
- Malformed request line.

The parser should not open sockets in tests.
