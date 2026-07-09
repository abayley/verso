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
module Verso.Attachment (
    AttachmentStore (..),
    allowedExtension,
    attachmentRoutes,
    contentHash,
    extensionOf,
    fileAttachmentStore,
    inlineImageExtension,
    originalUploadFilename,
    percentDecode,
    uploadFilename,
) where

import qualified Data.Bits as Bits
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.Maybe as Maybe
import qualified Data.Word as Word
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Static as Static
import qualified MicroHttp.Stream as Stream
import qualified Numeric
import qualified System.Directory as Directory

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
    Directory.createDirectoryIfMissing True root
    BS.writeFile (root ++ "/" ++ hash) bytes
    pure hash

-- | Resolves a hash to its blob path and size, or 'Nothing' if it is not stored.
resolveBlob :: FilePath -> String -> IO (Maybe (FilePath, Int))
resolveBlob root hash = do
    let path = root ++ "/" ++ hash
    exists <- Directory.doesFileExist path
    if not exists
        then pure Nothing
        else do
            sized <- Socket.fileSizeBytes path
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
fnv1a :: Word.Word64 -> BS.ByteString -> Word.Word64
fnv1a = BS.foldl' (\hash byte -> (hash `Bits.xor` fromIntegral (Char.ord byte)) * 1099511628211)

-- | A 'Word.Word64' as exactly 16 lowercase hex digits.
paddedHex :: Word.Word64 -> String
paddedHex value =
    let digits = Numeric.showHex value ""
     in replicate (16 - length digits) '0' ++ digits

-- | The upload and serving routes for an attachment store.
attachmentRoutes :: AttachmentStore -> [Router.Route]
attachmentRoutes store =
    [ Router.post "/attachments" (uploadAttachment store)
    , Router.get "/attachments/:hash/:name" (serveAttachment store)
    ]

{- | Receives a file as the raw request body, stores it under its content hash,
and returns @{"url": "/attachments/<hash>/<name>"}@. The filename comes from the
@X-Attachment-Filename@ header (percent-encoded); its extension gates the type
allow-list (a disallowed type is @415@) and drives the served content type.
-}
uploadAttachment :: AttachmentStore -> Router.Handler
uploadAttachment store _ request = do
    bytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) attachmentMaxBytes
    let name = uploadFilename request
    if not (allowedExtension (extensionOf name))
        then pure (statusResponse 415 "Unsupported Media Type" "attachment type is not allowed\n")
        else do
            hash <- Iteratee.liftIO (putAttachment store bytes)
            pure (jsonResponse ("{\"url\":\"/attachments/" ++ hash ++ "/" ++ name ++ "\"}"))

{- | Serves a stored blob as a zero-copy 'FileBody' with hardening headers, or a
@404@ when the hash is malformed or absent. The @:name@ segment is cosmetic (the
download filename and the content-type extension); only the validated hex hash
addresses the filesystem, so the path cannot be escaped.
-}
serveAttachment :: AttachmentStore -> Router.Handler
serveAttachment store captures _ = do
    let hash = captureValue "hash" captures
        name = captureValue "name" captures
    if not (validHash hash)
        then pure notFoundResponse
        else do
            resolved <- Iteratee.liftIO (resolveAttachment store hash)
            case resolved of
                Nothing -> pure notFoundResponse
                Just (path, size) -> pure (attachmentResponse name path size)

-- | The blob response: the file body plus the content type and hardening headers.
attachmentResponse :: String -> FilePath -> Int -> Http.Response
attachmentResponse name path size =
    Http.Response Http.okStatus (attachmentHeaders name) (Http.FileBody path size)

-- | The serving headers for a blob: content type plus the hardening set.
attachmentHeaders :: String -> [Http.Header]
attachmentHeaders name =
    [ header "Content-Type" (Static.contentTypeFor name)
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
uploadFilename :: Http.RequestHead -> String
uploadFilename request =
    case lookup (Http.normaliseHeaderName (BS.pack "x-attachment-filename")) (Http.requestHeaders request) of
        Just raw -> sanitiseFilename (percentDecode (BS.unpack raw))
        Nothing -> "file"

{- | The percent-decoded upload filename (its last path segment), unsanitised, for
display and metadata: the human-readable original name with its spaces and case
intact (e.g. @My Report.pdf@). Unlike 'uploadFilename' (which sanitises for use
as a stored filename and URL segment), this is never used as a path -- it is the
@name@/@short_title@ recorded in the sidecar metadata (RFC-0019).
-}
originalUploadFilename :: Http.RequestHead -> String
originalUploadFilename request =
    case lookup (Http.normaliseHeaderName (BS.pack "x-attachment-filename")) (Http.requestHeaders request) of
        Just raw -> case lastSegment (percentDecode (BS.unpack raw)) of
            "" -> "file"
            name -> name
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

-- | Whether a character is safe in a filename segment (letters, digits, @. _ -@).
safeFilenameChar :: Char -> Bool
safeFilenameChar c =
    Char.isAsciiLower c || Char.isAsciiUpper c || Char.isDigit c || c == '.' || c == '_' || c == '-'

-- | The last path segment of a name (drops any directory prefix from the client).
lastSegment :: String -> String
lastSegment = reverse . takeWhile (/= '/') . reverse

-- | A hash addresses the store only when it is exactly 32 lowercase hex digits.
validHash :: String -> Bool
validHash hash =
    length hash == 32 && all isLowerHexDigit hash

-- | Whether a character is a lowercase hex digit (@0-9@ or @a-f@).
isLowerHexDigit :: Char -> Bool
isLowerHexDigit c =
    Char.isDigit c || (c >= 'a' && c <= 'f')

-- | The lower-cased extension of a name's last segment, or @""@ if it has none.
extensionOf :: String -> String
extensionOf name =
    case span (/= '.') (reverse (lastSegment name)) of
        (revExtension, '.' : _) -> map Char.toLower (reverse revExtension)
        (_, _) -> ""

-- | A minimal percent-decoder for the filename header (decodes @%XX@; leaves @+@).
percentDecode :: String -> String
percentDecode [] = []
percentDecode ('%' : high : low : rest)
    | Just h <- hexValue high, Just l <- hexValue low = toEnum (h * 16 + l) : percentDecode rest
percentDecode (c : rest) = c : percentDecode rest

-- | The numeric value of a single hex digit (any case), or 'Nothing' if not one.
hexValue :: Char -> Maybe Int
hexValue c
    | Char.isDigit c = Just (fromEnum c - fromEnum '0')
    | c >= 'a' && c <= 'f' = Just (fromEnum c - fromEnum 'a' + 10)
    | c >= 'A' && c <= 'F' = Just (fromEnum c - fromEnum 'A' + 10)
    | otherwise = Nothing

-- | The value of a named route capture, or @""@ when it is absent.
captureValue :: String -> Router.Captures -> String
captureValue key captures =
    Maybe.fromMaybe "" (lookup key captures)

-- | A response header from a name and value, with the name normalised.
header :: String -> String -> Http.Header
header name value =
    (Http.normaliseHeaderName (BS.pack name), BS.pack value)

-- | A @200@ JSON response from a body string.
jsonResponse :: String -> Http.Response
jsonResponse body =
    Http.Response Http.okStatus [header "Content-Type" "application/json"] (Http.StrictBody (BS.pack body))

-- | A plain-text response from a status code, reason phrase, and body.
statusResponse :: Int -> String -> String -> Http.Response
statusResponse code reason body =
    Http.Response (Http.Status code reason) [header "Content-Type" "text/plain"] (Http.StrictBody (BS.pack body))

-- | The shared @404 Not Found@ plain-text response.
notFoundResponse :: Http.Response
notFoundResponse =
    statusResponse 404 "Not Found" "not found\n"
