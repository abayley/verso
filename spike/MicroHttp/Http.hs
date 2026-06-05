module MicroHttp.Http where

data Request = Request
  { requestMethod :: String
  , requestPath :: [String]
  , requestQuery :: [(String, String)]
  , requestHeaders :: [(String, String)]
  , requestBody :: String
  , requestRawPath :: String
  } deriving (Eq, Show)

data Response = Response
  { responseStatus :: Int
  , responseStatusText :: String
  , responseHeaders :: [(String, String)]
  , responseBody :: String
  } deriving (Eq, Show)

data ParseError
  = BadRequest String
  | HeaderTooLarge
  | BodyTooLarge
  | UnsupportedTransferEncoding
  | UnsupportedHttpVersion
  deriving (Eq, Show)

okText :: String -> Response
okText body =
  Response 200 "OK" [("Content-Type", "text/plain")] body

okHtml :: String -> Response
okHtml body =
  Response 200 "OK" [("Content-Type", "text/html")] body

notFound :: Response
notFound =
  Response 404 "Not Found" [("Content-Type", "text/plain")] "not found\n"

methodNotAllowed :: Response
methodNotAllowed =
  Response 405 "Method Not Allowed" [("Content-Type", "text/plain")] "method not allowed\n"
