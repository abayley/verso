# HTTP Types Module Design

## HTTP Types Module Purpose

`MicroHttp.Http` defines the shared request, response, method, status, header,
and body types used by parser, server, router, middleware, and applications.

## HTTP Types Module Responsibilities

- Define `Request`.
- Define `Response`.
- Define `Method`, `Status`, `Headers`, and `Body`.
- Provide constructors for common responses.
- Keep invalid or unsupported HTTP states visible.

## HTTP Types Module Non-Responsibilities

- Parsing bytes into requests.
- Serialising responses into bytes.
- Matching routes.
- Rendering HTML.

## HTTP Types Module Public Interface Sketch

```haskell
data Request = Request
  { requestMethod :: Method
  , requestPath :: [Text]
  , requestQuery :: [(Text, Text)]
  , requestHeaders :: Headers
  , requestBody :: BodyBytes
  , requestRawPath :: RawPath
  }

data Response = Response
  { responseStatus :: Status
  , responseHeaders :: Headers
  , responseBody :: ResponseBody
  }

data Method
  = GET
  | POST
  | PUT
  | PATCH
  | DELETE
  | HEAD
  | OPTIONS

newtype HeaderName = HeaderName ByteString

data ResponseBody
  = StrictBody ByteString
  | FileBody FilePath
```

The spike code uses `String` to reduce MicroHs compatibility noise. Production
HTTP wire types should move to strict `ByteString` before the first milestone.

## HTTP Types Module Decisions

- `Method` is a closed sum type. The parser chooses the constructor at parse
  time and rejects unknown methods.
- Request header names are normalised at parse time. The `Headers` type should
  preserve a lower-case header-name invariant.
- Response bodies support strict bytes and files in the first implementation.

These decisions and their rationale are recorded in the
[MicroHttp ADR Registry](../decision-register.md).

## HTTP Types Module Method Consequences

A closed method type makes route definitions and method override simpler because
handlers can pattern match on constructors instead of comparing raw bytes.

The tradeoff is that HTTP extension methods are not representable. That is
acceptable for the first browser-oriented milestone. If extension methods become
important, add an `OtherMethod ByteString` constructor deliberately rather than
changing handlers to use raw text everywhere.

## HTTP Types Module File Body Consequences

`FileBody` makes static assets and large responses part of the response model
without introducing an external streaming library.

Strict bodies can be fully serialised with `Content-Length`. File bodies need an
effectful writer because the response layer must open the file and send chunks.
MicroHs does not currently export `getFileSize`, so initial file responses may
omit `Content-Length` and rely on `Connection: close`, or the network layer may
add a small file-size capability later.
