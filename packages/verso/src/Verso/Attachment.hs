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
