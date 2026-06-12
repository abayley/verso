module MicroHttp.Router (
    Captures,
    Handler,
    Route,
    delete,
    get,
    post,
    route,
) where

import qualified Data.ByteString.Char8 as BS
import Data.List (intercalate)
import MicroHttp.Http
import MicroHttp.Iteratee (Iter)
import MicroHttp.Stream (StreamError)

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
