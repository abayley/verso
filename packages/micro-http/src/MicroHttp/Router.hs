{- | Matching a request to a handler.

A 'Route' pairs a method and a path pattern with a 'Handler'; 'route' builds one,
'serveRoutes' tries them in order and answers 'notFound' when none matches. A
pattern's segments may capture, and the captured values reach the handler as
'Captures'.

Routing happens after the head is parsed and before the body is read, so a handler
receives the request head and the still-unread body stream and decides what to do
with it: this is what lets a handler stream a large upload rather than be handed
it (RFC-0012). 'frameAndParse' is that boundary.
-}
module MicroHttp.Router (
    Captures,
    Handler,
    Route,
    delete,
    frameAndParse,
    get,
    notFound,
    post,
    put,
    route,
    serveRoutes,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Stream as Stream
import qualified MicroHttp.Utf8 as Utf8

-- | Path captures collected while matching a route, as name/value pairs.
type Captures = [(String, String)]

-- | A request handler: captures and the parsed head to a response iteratee.
type Handler = Captures -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response

data Route = Route Http.Method [PathPart] Handler

data PathPart
    = Lit String
    | Capture String
    | Rest String
    deriving (Eq, Show)

-- | A route matching @GET@ on the given path pattern.
get :: String -> Handler -> Route
get = routeFor Http.GET

-- | A route matching @POST@ on the given path pattern.
post :: String -> Handler -> Route
post = routeFor Http.POST

-- | A route matching @PUT@ on the given path pattern.
put :: String -> Handler -> Route
put = routeFor Http.PUT

-- | A route matching @DELETE@ on the given path pattern.
delete :: String -> Handler -> Route
delete = routeFor Http.DELETE

{- | Dispatches a request to the first matching route, distinguishing an unknown
path (404) from a known path with no matching method (405).
-}
route :: [Route] -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
route routes request =
    case matchingPath routes (Http.requestPath request) of
        [] -> pure notFound
        pathMatches ->
            case matchingMethod pathMatches (Http.requestMethod request) of
                Just (captures, handler) -> handler captures request
                Nothing -> pure methodNotAllowed

{- | An application built from routes: frame and parse the head, bound the body
to the declared @Content-Length@ (rejecting an over-limit or malformed length),
then dispatch. Framing lives here, at the bottom of the application stack, not
in the server. The connection metadata is unused for now.
-}
serveRoutes :: Http.ParseLimits -> [Route] -> Http.Application
serveRoutes limits routes conn =
    frameAndParse limits >>= \head -> withBody head{Http.requestPeer = conn}
  where
    withBody head =
        case declaredContentLength (Http.requestHeaders head) of
            Left err -> failWith (Stream.StreamParseError err)
            Right bodyLength
                | bodyLength > Http.maxBodyBytes limits ->
                    failWith (Stream.StreamParseError Http.BodyTooLarge)
                | otherwise -> Iteratee.takeN bodyLength (route routes head)

-- | Frames the header block and parses it, failing the stream on a bad head.
frameAndParse :: Http.ParseLimits -> Iteratee.Iter Stream.StreamError Http.RequestHead
frameAndParse limits =
    Http.frameHeadersI limits >>= parsed
  where
    parsed headerBytes =
        case Http.parseRequestHead headerBytes of
            Left err -> failWith (Stream.StreamParseError err)
            Right head -> pure head

-- | A pipeline failure becomes an iteratee failure with empty residue.
failWith :: Stream.StreamError -> Iteratee.Iter Stream.StreamError a
failWith err = Iteratee.IterFailed err (Iteratee.Chunk BS.empty)

{- | The declared body length: a missing @Content-Length@ means no body, a
well-formed value is its length, and a non-numeric value is rejected.
-}
declaredContentLength :: Http.Headers -> Either Http.ParseError Int
declaredContentLength headers =
    case lookupHeaderValue "content-length" headers of
        Nothing -> Right 0
        Just value
            | value /= "" && all Char.isDigit value -> Right (read value)
            | otherwise -> Left (Http.BadRequest "invalid content-length")

{- | Looks up a header value by name, comparing on the normalised header name. A
field value is ASCII on the wire (RFC 9110 section 5.5); it is decoded as UTF-8 so
that a non-ASCII octet, should one arrive, is a character rather than a byte.
-}
lookupHeaderValue :: String -> Http.Headers -> Maybe String
lookupHeaderValue _ [] = Nothing
lookupHeaderValue name ((key, value) : rest)
    | Http.normaliseHeaderName (BS.pack name) == key = Just (Utf8.decodeBytes value)
    | otherwise = lookupHeaderValue name rest

-- | Builds a route for a method from a path pattern and handler.
routeFor :: Http.Method -> String -> Handler -> Route
routeFor method patternText =
    Route method (parsePattern patternText)

-- | All routes whose path pattern matches, each paired with its captures.
matchingPath :: [Route] -> [String] -> [(Captures, Route)]
matchingPath [] _ = []
matchingPath (candidate : rest) path =
    case matchPath candidate path of
        Just captures -> (captures, candidate) : matchingPath rest path
        Nothing -> matchingPath rest path

-- | The first path match whose route method equals the request method.
matchingMethod :: [(Captures, Route)] -> Http.Method -> Maybe (Captures, Handler)
matchingMethod [] _ = Nothing
matchingMethod ((captures, Route routeMethod _ handler) : rest) method
    | routeMethod == method = Just (captures, handler)
    | otherwise = matchingMethod rest method

-- | Matches a route's path parts against path segments, collecting captures.
matchPath :: Route -> [String] -> Maybe Captures
matchPath (Route _ parts _) path = go parts path []
  where
    go [] [] captures = Just (reverse captures)
    go (Rest name : _) restPath captures =
        Just (reverse ((name, List.intercalate "/" restPath) : captures))
    go (Lit expected : restParts) (actual : restPath) captures
        | expected == actual = go restParts restPath captures
        | otherwise = Nothing
    go (Capture name : restParts) (actual : restPath) captures =
        go restParts restPath ((name, actual) : captures)
    go _ _ _ = Nothing

-- | Parses a path pattern into its parts, dropping empty segments.
parsePattern :: String -> [PathPart]
parsePattern patternText = map parsePart (filter (/= "") (splitOn '/' patternText))
  where
    parsePart (':' : name) = Capture name
    parsePart ('*' : name) = Rest name
    parsePart text = Lit text

-- | Splits a string on a separator character into segments.
splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]

{- | The framework's 404: a plain-text body, used for an unmatched route and by
'MicroHttp.Static' for a file that is absent, refused or outside its mount. One
response rather than one per module, so a server answers a miss the same way
whichever layer decided it was one.
-}
notFound :: Http.Response
notFound =
    Http.Response
        (Http.Status 404 "Not Found")
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (Http.StrictBody (BS.pack "not found\n"))

-- | The 405 response for a matched path with no matching method.
methodNotAllowed :: Http.Response
methodNotAllowed =
    Http.Response
        (Http.Status 405 "Method Not Allowed")
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (Http.StrictBody (BS.pack "method not allowed\n"))
