{- | Image and file attachments (RFC-0018). Uploaded bytes are stored once in a
content-addressed blob store and served back safely and zero-copy.

'attachmentRoutes' wires two routes onto a store: @POST /attachments@ receives a
file as the raw request body (the editor's @fetch@ upload, RFC-0018 -- not
multipart), stores it under its content hash, and returns the reference URL as
JSON; @GET /attachments/:hash/:name@ serves the blob as a 'FileBody' (zero-copy
@sendfile@, ADR-034) with a content type from the URL filename and hardening
headers (@nosniff@, a sandbox CSP, and download disposition for non-image types)
so untrusted bytes cannot execute or be re-interpreted. The content hash is a
non-cryptographic 128-bit FNV-1a (no crypto dependency in MicroHs); it provides
deduplication and a collision-free-in-practice address, not a security primitive
-- safety comes from the serving headers and the type allow-list.
-}
module MicroHttp.Attachment (
    AttachmentStore (..),
    attachmentRoutes,
    contentHash,
    fileAttachmentStore,
) where

import Data.Bits (xor)
import qualified Data.ByteString.Char8 as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, ord, toLower)
import Data.Maybe (fromMaybe)
import Data.Word (Word64)
import MicroHttp.Http (
    Header,
    RequestHead (..),
    Response (..),
    ResponseBody (..),
    Status (..),
    normaliseHeaderName,
    okStatus,
 )
import MicroHttp.Http.Parse (ParseError (..))
import MicroHttp.Iteratee (liftIO, readBodyStrict)
import MicroHttp.Network.Socket (fileSizeBytes)
import MicroHttp.Router (Captures, Handler, Route, get, post)
import MicroHttp.Static (contentTypeFor)
import MicroHttp.Stream (StreamError (..))
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, doesFileExist)

-- | The maximum accepted upload size in bytes (RFC-0018; the server cap must be at least this).
attachmentMaxBytes :: Int
attachmentMaxBytes = 10485760

{- | A content-addressed attachment store. 'putAttachment' stores bytes and
returns their hash (the address); 'resolveAttachment' resolves a hash to the
blob's path and size for serving, or 'Nothing' when it is absent.
-}
data AttachmentStore = AttachmentStore
    { putAttachment :: BS.ByteString -> IO String
    , resolveAttachment :: String -> IO (Maybe (FilePath, Int))
    }

-- | A filesystem attachment store: blobs live at @root/<hash>@.
fileAttachmentStore :: FilePath -> AttachmentStore
fileAttachmentStore root =
    AttachmentStore
        { putAttachment = putBlob root
        , resolveAttachment = resolveBlob root
        }

{- | Stores bytes at @root/<hash>@ and returns the hash. The write is direct
(MicroHs has no atomic @renameFile@): because the path is content-addressed, an
identical re-upload overwrites with identical bytes -- idempotent dedup that also
self-heals a blob left partial by an interrupted earlier write.
-}
putBlob :: FilePath -> BS.ByteString -> IO String
putBlob root bytes = do
    let hash = contentHash bytes
    createDirectoryIfMissing True root
    BS.writeFile (root ++ "/" ++ hash) bytes
    pure hash

-- | Resolves a hash to its blob path and size, or 'Nothing' if it is not stored.
resolveBlob :: FilePath -> String -> IO (Maybe (FilePath, Int))
resolveBlob root hash = do
    let path = root ++ "/" ++ hash
    exists <- doesFileExist path
    if not exists
        then pure Nothing
        else do
            sized <- fileSizeBytes path
            pure (fmap (pathAndSize path) sized)
  where
    pathAndSize p size = (p, size)

{- | A non-cryptographic 128-bit content hash (two 64-bit FNV-1a passes with
different offset bases, each zero-padded to 16 hex digits). Deterministic and
collision-free in practice for an attachment store; not a security primitive.
-}
contentHash :: BS.ByteString -> String
contentHash bytes =
    paddedHex (fnv1a 14695981039346656037 bytes) ++ paddedHex (fnv1a 1469598103934665603 bytes)

{- | One FNV-1a pass over the bytes from a given offset basis (64-bit, wrapping).
A strict left fold directly over the 'ByteString' so a large upload neither
unpacks to a list nor builds a deep thunk chain.
-}
fnv1a :: Word64 -> BS.ByteString -> Word64
fnv1a = BS.foldl' (\hash byte -> (hash `xor` fromIntegral (ord byte)) * 1099511628211)

-- | A 'Word64' as exactly 16 lowercase hex digits.
paddedHex :: Word64 -> String
paddedHex value =
    let digits = showHex value ""
     in replicate (16 - length digits) '0' ++ digits

-- | The upload and serving routes for an attachment store.
attachmentRoutes :: AttachmentStore -> [Route]
attachmentRoutes store =
    [ post "/attachments" (uploadAttachment store)
    , get "/attachments/:hash/:name" (serveAttachment store)
    ]

{- | Receives a file as the raw request body, stores it under its content hash,
and returns @{"url": "/attachments/<hash>/<name>"}@. The filename comes from the
@X-Attachment-Filename@ header (percent-encoded); its extension gates the type
allow-list (a disallowed type is @415@) and drives the served content type.
-}
uploadAttachment :: AttachmentStore -> Handler
uploadAttachment store _ request = do
    bytes <- readBodyStrict (StreamParseError BodyTooLarge) attachmentMaxBytes
    let name = uploadFilename request
    if not (allowedExtension (extensionOf name))
        then pure (statusResponse 415 "Unsupported Media Type" "attachment type is not allowed\n")
        else do
            hash <- liftIO (putAttachment store bytes)
            pure (jsonResponse ("{\"url\":\"/attachments/" ++ hash ++ "/" ++ name ++ "\"}"))

{- | Serves a stored blob as a zero-copy 'FileBody' with hardening headers, or a
@404@ when the hash is malformed or absent. The @:name@ segment is cosmetic (the
download filename and the content-type extension); only the validated hex hash
addresses the filesystem, so the path cannot be escaped.
-}
serveAttachment :: AttachmentStore -> Handler
serveAttachment store captures _ = do
    let hash = captureValue "hash" captures
        name = captureValue "name" captures
    if not (validHash hash)
        then pure notFoundResponse
        else do
            resolved <- liftIO (resolveAttachment store hash)
            case resolved of
                Nothing -> pure notFoundResponse
                Just (path, size) -> pure (attachmentResponse name path size)

-- | The blob response: the file body plus the content type and hardening headers.
attachmentResponse :: String -> FilePath -> Int -> Response
attachmentResponse name path size =
    Response okStatus (attachmentHeaders name) (FileBody path size)

attachmentHeaders :: String -> [Header]
attachmentHeaders name =
    [ header "Content-Type" (contentTypeFor name)
    , header "X-Content-Type-Options" "nosniff"
    , header "Content-Security-Policy" "default-src 'none'; sandbox"
    , header "Content-Disposition" (disposition name)
    , header "Cache-Control" "public, max-age=31536000, immutable"
    ]

{- | Inline disposition for the inline-renderable image types; download
disposition for everything else (including SVG, which can carry script).
-}
disposition :: String -> String
disposition name
    | inlineImageExtension (extensionOf name) = "inline"
    | otherwise = "attachment; filename=\"" ++ name ++ "\""

-- | The image types served inline; all other allowed types are downloads.
inlineImageExtension :: String -> Bool
inlineImageExtension ext =
    ext `elem` ["png", "jpg", "jpeg", "gif", "webp"]

{- | The upload type allow-list: the inline image types plus a fixed set of
document types. SVG is allowed but served as a download (see 'disposition').
-}
allowedExtension :: String -> Bool
allowedExtension ext =
    inlineImageExtension ext || ext `elem` ["svg", "pdf", "txt", "md", "csv", "json", "zip"]

-- | The percent-decoded, sanitised upload filename, or @"file"@ when unusable.
uploadFilename :: RequestHead -> String
uploadFilename request =
    case lookup (normaliseHeaderName (BS.pack "x-attachment-filename")) (requestHeaders request) of
        Just raw -> sanitiseFilename (percentDecode (BS.unpack raw))
        Nothing -> "file"

{- | Restricts a filename to a safe URL/path segment: letters, digits, and
@. _ -@, with anything else replaced by @_@, and the special segments @.@/@..@
and the empty string mapped to @"file"@ (the name never touches the filesystem,
but this keeps the URL and JSON clean and unambiguous).
-}
sanitiseFilename :: String -> String
sanitiseFilename raw =
    let cleaned = map keepSafe (lastSegment raw)
     in if cleaned == "" || cleaned == "." || cleaned == ".."
            then "file"
            else cleaned
  where
    keepSafe c
        | safeFilenameChar c = c
        | otherwise = '_'

safeFilenameChar :: Char -> Bool
safeFilenameChar c =
    isAsciiLower c || isAsciiUpper c || isDigit c || c == '.' || c == '_' || c == '-'

-- | The last path segment of a name (drops any directory prefix from the client).
lastSegment :: String -> String
lastSegment = reverse . takeWhile (/= '/') . reverse

-- | A hash addresses the store only when it is exactly 32 lowercase hex digits.
validHash :: String -> Bool
validHash hash =
    length hash == 32 && all isLowerHexDigit hash

isLowerHexDigit :: Char -> Bool
isLowerHexDigit c =
    isDigit c || (c >= 'a' && c <= 'f')

-- | The lower-cased extension of a name's last segment, or @""@ if it has none.
extensionOf :: String -> String
extensionOf name =
    case span (/= '.') (reverse (lastSegment name)) of
        (revExtension, '.' : _) -> map toLower (reverse revExtension)
        (_, _) -> ""

-- | A minimal percent-decoder for the filename header (decodes @%XX@; leaves @+@).
percentDecode :: String -> String
percentDecode [] = []
percentDecode ('%' : high : low : rest)
    | Just h <- hexValue high, Just l <- hexValue low = toEnum (h * 16 + l) : percentDecode rest
percentDecode (c : rest) = c : percentDecode rest

hexValue :: Char -> Maybe Int
hexValue c
    | isDigit c = Just (fromEnum c - fromEnum '0')
    | c >= 'a' && c <= 'f' = Just (fromEnum c - fromEnum 'a' + 10)
    | c >= 'A' && c <= 'F' = Just (fromEnum c - fromEnum 'A' + 10)
    | otherwise = Nothing

captureValue :: String -> Captures -> String
captureValue key captures =
    fromMaybe "" (lookup key captures)

header :: String -> String -> Header
header name value =
    (normaliseHeaderName (BS.pack name), BS.pack value)

jsonResponse :: String -> Response
jsonResponse body =
    Response okStatus [header "Content-Type" "application/json"] (StrictBody (BS.pack body))

statusResponse :: Int -> String -> String -> Response
statusResponse code reason body =
    Response (Status code reason) [header "Content-Type" "text/plain"] (StrictBody (BS.pack body))

notFoundResponse :: Response
notFoundResponse =
    statusResponse 404 "Not Found" "not found\n"
