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
    safeComponent,
    contentTypeFor,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Router as Router
import qualified System.Directory as Directory

{- | Mounts the filesystem @root@ under the URL @prefix@ as a GET wildcard
route. A request to @prefix/<rest>@ serves @root/<rest>@ if it is an existing
regular file, and 404s otherwise.
-}
static :: String -> FilePath -> Router.Route
static prefix root =
    Router.get (prefix ++ "/*rest") (serveStatic (prefixSegmentCount prefix) root)

{- | Serves a file from @root@ for the request path beyond the @prefixCount@
mount segments. The path is resolved safely; a missing file, a directory, or
an unsafe path is a 404, decided before the head is written.
-}
serveStatic :: Int -> FilePath -> Router.Handler
serveStatic prefixCount root _ request =
    Iteratee.IterM (fmap pure (resolve (drop prefixCount (Http.requestPath request))))
  where
    resolve components =
        case resolveStaticPath root components of
            Nothing -> pure Router.notFound
            Just path -> serveResolved path

-- | Serves @path@ as a sized file response if it is a regular file, else 404s.
serveResolved :: FilePath -> IO Http.Response
serveResolved path = do
    isFile <- Directory.doesFileExist path
    isDirectory <- Directory.doesDirectoryExist path
    if isFile && not isDirectory
        then sizedFileResponse path
        else pure Router.notFound

{- | Resolves the file size once and builds a zero-copy 'FileBody' carrying it;
if the file cannot be sized (a race after the existence check), answers 404.
-}
sizedFileResponse :: FilePath -> IO Http.Response
sizedFileResponse path = do
    sized <- Socket.fileSizeBytes path
    case sized of
        Just size -> pure (fileResponse (contentTypeFor path) path size)
        Nothing -> pure Router.notFound

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

{- | True if a path component is safe: non-empty, not @.@ or @..@, and free of
path separators or a NUL. The one path-safety rule in the tree: 'resolveStaticPath'
applies it to a request path, and an application building paths from its own
segments (a validated path type, a file name from a header) applies it before
handing them to 'MicroHttp.FileSystem'.
-}
safeComponent :: String -> Bool
safeComponent component =
    not (null component)
        && component /= "."
        && component /= ".."
        && notElem '/' component
        && notElem '\\' component
        && notElem '\0' component

-- | Joins the root and the safe components into a served filesystem path.
buildPath :: FilePath -> [String] -> FilePath
buildPath root [] = root
buildPath root components = root ++ "/" ++ List.intercalate "/" components

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
        "webp" -> "image/webp"
        "woff2" -> "font/woff2"
        "txt" -> "text/plain"
        "md" -> "text/markdown"
        "csv" -> "text/csv"
        "pdf" -> "application/pdf"
        "zip" -> "application/zip"
        "ico" -> "image/x-icon"
        _ -> "application/octet-stream"

-- | The lower-cased extension of a path's last component, or @""@ if none.
extensionOf :: FilePath -> String
extensionOf path =
    case span (/= '.') (reverse (lastComponent path)) of
        (revExtension, '.' : _) -> map Char.toLower (reverse revExtension)
        (_, _) -> ""

-- | The last @/@-separated component of a path.
lastComponent :: FilePath -> String
lastComponent = reverse . takeWhile (/= '/') . reverse

-- | A 200 'Http.FileBody' response for @path@ with the given content type and size.
fileResponse :: String -> FilePath -> Int -> Http.Response
fileResponse contentType path size =
    Http.Response
        Http.okStatus
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack contentType)]
        (Http.FileBody path size)

-- | The number of non-empty @/@-separated segments in a mount prefix.
prefixSegmentCount :: String -> Int
prefixSegmentCount = length . filter (not . null) . splitSlash

-- | Splits a string on @/@ into its segments.
splitSlash :: String -> [String]
splitSlash text =
    case break (== '/') text of
        (before, _ : after) -> before : splitSlash after
        (before, []) -> [before]
