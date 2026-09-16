{- | Upload filename and type policy for page assets (RFC-0018/RFC-0019): the
upload filename headers (@X-Attachment-Filename@, percent-encoded), the
sanitised-vs-original filename split, the extension allow-list, and the
inline-image classification. The tree's @?asset@ upload handler consumes
these; the retired flat-mode blob store that once lived here went with
RFC-0036 (tree assets are stored as a page's peer files, RFC-0018 as
amended).
-}
module Verso.Attachment (
    allowedExtension,
    extensionOf,
    inlineImageExtension,
    originalUploadFilename,
    percentDecode,
    uploadFilename,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Utf8 as Utf8

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
        Just raw -> sanitiseFilename (Utf8.decodeUtf8 (percentDecode (BS.unpack raw)))
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
        Just raw -> case lastSegment (Utf8.decodeUtf8 (percentDecode (BS.unpack raw))) of
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

-- | The lower-cased extension of a name's last segment, or @""@ if it has none.
extensionOf :: String -> String
extensionOf name =
    case span (/= '.') (reverse (lastSegment name)) of
        (revExtension, '.' : _) -> map Char.toLower (reverse revExtension)
        (_, _) -> ""

{- | Percent-decodes the filename header: @%XX@ becomes its byte and a @+@ is
left alone, which is the framework's path-segment rule ('Http.decodePathSegment').
This was a fourth copy of that rule until the decoders were unified.
-}
percentDecode :: String -> String
percentDecode = Http.decodePathSegment
