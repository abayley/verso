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
```

The spike code uses `String` to reduce MicroHs compatibility noise. The
implementation design should decide whether to keep `String` initially or move
to MicroHs `ByteString` before the first milestone.

## HTTP Types Module Open Decisions

- Whether `Method` is a closed sum type or a newtype over `String`.
- Whether headers are case-normalised at parse time.
- Whether response body supports files in the first implementation or waits
  until after HTML/form workflows work.
