module MicroHttp.Router (
    Captures,
    Handler,
    Route,
    delete,
    frameAndParse,
    get,
    post,
    route,
    serveRoutes,
) where

import qualified Data.ByteString.Char8 as BS
import Data.Char (isDigit)
import Data.List (intercalate)
import MicroHttp.Http
import MicroHttp.Http.Framing (frameHeadersI)
import MicroHttp.Http.Parser (ParseError (..), ParseLimits (..), parseRequestHead)
import MicroHttp.Iteratee (Iter (..), Stream (..), takeN)
import MicroHttp.Stream (StreamError (..))

type Captures = [(String, String)]

type Handler = Captures -> RequestHead -> Iter StreamError Response

data Route = Route Method [PathPart] Handler

data PathPart
    = Lit String
    | Capture String
    | Rest String
    deriving (Eq, Show)

get :: String -> Handler -> Route
get = routeFor GET

post :: String -> Handler -> Route
post = routeFor POST

delete :: String -> Handler -> Route
delete = routeFor DELETE

route :: [Route] -> RequestHead -> Iter StreamError Response
route routes request =
    case matchingPath routes (requestPath request) of
        [] -> pure notFound
        pathMatches ->
            case matchingMethod pathMatches (requestMethod request) of
                Just (captures, handler) -> handler captures request
                Nothing -> pure methodNotAllowed

{- | An application built from routes: frame and parse the head, bound the body
to the declared @Content-Length@ (rejecting an over-limit or malformed length),
then dispatch. Framing lives here, at the bottom of the application stack, not
in the server. The connection metadata is unused for now.
-}
serveRoutes :: ParseLimits -> [Route] -> Application
serveRoutes limits routes conn =
    frameAndParse limits >>= \head -> withBody head{requestPeer = conn}
  where
    withBody head =
        case declaredContentLength (requestHeaders head) of
            Left err -> failWith (StreamParseError err)
            Right bodyLength
                | bodyLength > maxBodyBytes limits ->
                    failWith (StreamParseError BodyTooLarge)
                | otherwise -> takeN bodyLength (route routes head)

-- | Frames the header block and parses it, failing the stream on a bad head.
frameAndParse :: ParseLimits -> Iter StreamError RequestHead
frameAndParse limits =
    frameHeadersI limits >>= parsed
  where
    parsed headerBytes =
        case parseRequestHead headerBytes of
            Left err -> failWith (StreamParseError err)
            Right head -> pure head

-- | A pipeline failure becomes an iteratee failure with empty residue.
failWith :: StreamError -> Iter StreamError a
failWith err = IterFailed err (Chunk BS.empty)

{- | The declared body length: a missing @Content-Length@ means no body, a
well-formed value is its length, and a non-numeric value is rejected.
-}
declaredContentLength :: Headers -> Either ParseError Int
declaredContentLength headers =
    case lookupHeaderValue "content-length" headers of
        Nothing -> Right 0
        Just value
            | value /= "" && all isDigit value -> Right (read value)
            | otherwise -> Left (BadRequest "invalid content-length")

lookupHeaderValue :: String -> Headers -> Maybe String
lookupHeaderValue _ [] = Nothing
lookupHeaderValue name ((key, value) : rest)
    | normaliseHeaderName (BS.pack name) == key = Just (BS.unpack value)
    | otherwise = lookupHeaderValue name rest

routeFor :: Method -> String -> Handler -> Route
routeFor method patternText =
    Route method (parsePattern patternText)

matchingPath :: [Route] -> [String] -> [(Captures, Route)]
matchingPath [] _ = []
matchingPath (candidate : rest) path =
    case matchPath candidate path of
        Just captures -> (captures, candidate) : matchingPath rest path
        Nothing -> matchingPath rest path

matchingMethod :: [(Captures, Route)] -> Method -> Maybe (Captures, Handler)
matchingMethod [] _ = Nothing
matchingMethod ((captures, Route routeMethod _ handler) : rest) method
    | routeMethod == method = Just (captures, handler)
    | otherwise = matchingMethod rest method

matchPath :: Route -> [String] -> Maybe Captures
matchPath (Route _ parts _) path = go parts path []
  where
    go [] [] captures = Just (reverse captures)
    go (Rest name : _) restPath captures =
        Just (reverse ((name, intercalate "/" restPath) : captures))
    go (Lit expected : restParts) (actual : restPath) captures
        | expected == actual = go restParts restPath captures
        | otherwise = Nothing
    go (Capture name : restParts) (actual : restPath) captures =
        go restParts restPath ((name, actual) : captures)
    go _ _ _ = Nothing

parsePattern :: String -> [PathPart]
parsePattern patternText = map parsePart (filter (/= "") (splitOn '/' patternText))
  where
    parsePart (':' : name) = Capture name
    parsePart ('*' : name) = Rest name
    parsePart text = Lit text

splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]

notFound :: Response
notFound =
    Response
        (Status 404 "Not Found")
        [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (StrictBody (BS.pack "not found\n"))

methodNotAllowed :: Response
methodNotAllowed =
    Response
        (Status 405 "Method Not Allowed")
        [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (StrictBody (BS.pack "method not allowed\n"))
