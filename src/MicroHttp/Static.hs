{- | Static file serving (RFC-0010, RFC-0014). 'static' mounts a filesystem root
under a URL prefix as a wildcard route; 'serveStatic' is the handler. The served
path is built from the request's already-decoded path segments, not from a
rejoined capture, and every component is checked, so neither @..@ nor an encoded
separator can escape the root. A missing target or a directory is a 404 decided
before any response head is written. An existing file is served as a 'FileBody':
its size is resolved once here and carried on the body, giving an exact
@Content-Length@ and a zero-copy @sendfile@ send (RFC-0014).
-}
module MicroHttp.Static (
    static,
    serveStatic,
    resolveStaticPath,
    contentTypeFor,
) where

import qualified Data.ByteString.Char8 as BS
import Data.Char (toLower)
import Data.List (intercalate)
import MicroHttp.Http (RequestHead (..), Response (..), ResponseBody (..), Status (..), normaliseHeaderName, okStatus)
import MicroHttp.Iteratee (Iter (..))
import MicroHttp.Network.Socket (fileSizeBytes)
import MicroHttp.Router (Handler, Route, get)
import System.Directory (doesDirectoryExist, doesFileExist)

{- | Mounts the filesystem @root@ under the URL @prefix@ as a GET wildcard
route. A request to @prefix/<rest>@ serves @root/<rest>@ if it is an existing
regular file, and 404s otherwise.
-}
static :: String -> FilePath -> Route
static prefix root =
    get (prefix ++ "/*rest") (serveStatic (prefixSegmentCount prefix) root)

{- | Serves a file from @root@ for the request path beyond the @prefixCount@
mount segments. The path is resolved safely; a missing file, a directory, or
an unsafe path is a 404, decided before the head is written.
-}
serveStatic :: Int -> FilePath -> Handler
serveStatic prefixCount root _ request =
    IterM (fmap pure (resolve (drop prefixCount (requestPath request))))
  where
    resolve components =
        case resolveStaticPath root components of
            Nothing -> pure notFoundResponse
            Just path -> serveResolved path

serveResolved :: FilePath -> IO Response
serveResolved path = do
    isFile <- doesFileExist path
    isDirectory <- doesDirectoryExist path
    if isFile && not isDirectory
        then sizedFileResponse path
        else pure notFoundResponse

{- | Resolves the file size once and builds a zero-copy 'FileBody' carrying it;
if the file cannot be sized (a race after the existence check), answers 404.
-}
sizedFileResponse :: FilePath -> IO Response
sizedFileResponse path = do
    sized <- fileSizeBytes path
    case sized of
        Just size -> pure (fileResponse (contentTypeFor path) path size)
        Nothing -> pure notFoundResponse

{- | Resolves the served filesystem path from the root and the request path
components, or 'Nothing' if any component is unsafe. A component is unsafe if
it is empty, @.@, @..@, or contains a path separator (the @%2f@ case) or a
NUL; because the components are already-decoded segments, this blocks both
literal and percent-encoded traversal.
-}
resolveStaticPath :: FilePath -> [String] -> Maybe FilePath
resolveStaticPath root components
    | all safeComponent components = Just (buildPath root components)
    | otherwise = Nothing

safeComponent :: String -> Bool
safeComponent component =
    not (null component)
        && component /= "."
        && component /= ".."
        && notElem '/' component
        && notElem '\\' component
        && notElem '\0' component

buildPath :: FilePath -> [String] -> FilePath
buildPath root [] = root
buildPath root components = root ++ "/" ++ intercalate "/" components

{- | The Content-Type for a path, chosen by its file extension and defaulting
to @application/octet-stream@.
-}
contentTypeFor :: FilePath -> String
contentTypeFor path =
    case extensionOf path of
        "html" -> "text/html"
        "css" -> "text/css"
        "js" -> "text/javascript"
        "json" -> "application/json"
        "svg" -> "image/svg+xml"
        "png" -> "image/png"
        "jpg" -> "image/jpeg"
        "jpeg" -> "image/jpeg"
        "gif" -> "image/gif"
        "woff2" -> "font/woff2"
        "txt" -> "text/plain"
        "ico" -> "image/x-icon"
        _ -> "application/octet-stream"

-- | The lower-cased extension of a path's last component, or @""@ if none.
extensionOf :: FilePath -> String
extensionOf path =
    case span (/= '.') (reverse (lastComponent path)) of
        (revExtension, '.' : _) -> map toLower (reverse revExtension)
        (_, _) -> ""

lastComponent :: FilePath -> String
lastComponent = reverse . takeWhile (/= '/') . reverse

fileResponse :: String -> FilePath -> Int -> Response
fileResponse contentType path size =
    Response
        okStatus
        [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack contentType)]
        (FileBody path size)

notFoundResponse :: Response
notFoundResponse =
    Response
        (Status 404 "Not Found")
        [(normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (StrictBody (BS.pack "not found\n"))

prefixSegmentCount :: String -> Int
prefixSegmentCount = length . filter (not . null) . splitSlash

splitSlash :: String -> [String]
splitSlash text =
    case break (== '/') text of
        (before, _ : after) -> before : splitSlash after
        (before, []) -> [before]
