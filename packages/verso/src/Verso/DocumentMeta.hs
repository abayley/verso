{- | Per-page sidecar metadata for the document tree (RFC-0019, ADR-0049). A tree
page @\<dir>/\<base>.md@ records its assets in the meta directory
@\<dir>/meta/\<base>.meta/@: @attachments.yaml@ lists the page's attachments,
@images.yaml@ its inline images (a third file, @meta.yaml@, is untouched here).

These files were produced by a legacy CMS export and carry fields and formatting
we must not disturb, so this module never reserialises a file. It only (1) appends
one new entry block (deduplicated by @local_path@), creating the directory and an
@[]@-seeded file on demand, or (2) surgically replaces a single @short_title@
value within a matched @local_path@ block. Every other byte stays identical.

The pure builders, the dedup/append, the surgical update, and the attachment
reader are exported so they are tested without the filesystem; thin @IO@ wrappers
apply them to a meta directory.
-}
module Verso.DocumentMeta (
    AttachmentEntry (..),
    metaDirectoryFor,
    renderAttachmentEntry,
    renderImageEntry,
    addEntryDedup,
    setImageShortTitle,
    parseAttachments,
    appendAttachment,
    appendImage,
    updateImageShortTitle,
    readAttachmentEntries,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Static as Static
import qualified System.Directory as Directory

-- | An attachment record as written for a new upload: the legacy @id@/@path@ are omitted (ADR-0049).
data AttachmentEntry = AttachmentEntry
    { attachmentName :: String
    -- ^ The original (human-readable) filename, spaces and case intact.
    , attachmentLocalPath :: String
    -- ^ The page-relative path of the stored asset, e.g. @assets/foo.pdf@.
    , attachmentExtension :: String
    -- ^ The lower-cased file extension.
    }
    deriving (Eq, Show)

{- | The meta directory of a tree document, or 'Nothing' if the document path is
unsafe. For @\<dir>/\<base>.md@ it is @\<dir>/meta/\<base>.meta@ (an @index.md@
page yields @\<dir>/meta/index.meta@). The path is validated as a tree-relative
file via 'Static.resolveStaticPath' (ADR-0030), so traversal is rejected.
-}
metaDirectoryFor :: FilePath -> String -> Maybe FilePath
metaDirectoryFor root path =
    fmap metaDir (Static.resolveStaticPath root (pathSegments path))
  where
    metaDir fsPath = dirName fsPath ++ "/meta/" ++ dropMarkdownExtension (fileName fsPath) ++ ".meta"

-- | A new attachment entry block (one YAML list item), ending in a newline.
renderAttachmentEntry :: AttachmentEntry -> String
renderAttachmentEntry entry =
    "- name: "
        ++ singleQuoted (attachmentName entry)
        ++ "\n  local_path: "
        ++ attachmentLocalPath entry
        ++ "\n  extension: "
        ++ attachmentExtension entry
        ++ "\n  external: false\n"

-- | A new inline-image entry block (one YAML list item), ending in a newline.
renderImageEntry :: String -> String -> String
renderImageEntry localPath shortTitle =
    "- local_path: "
        ++ localPath
        ++ "\n  short_title: "
        ++ singleQuoted shortTitle
        ++ "\n  description: ''\n"

{- | Add an entry block to a list file's contents, deduplicated by @local_path@:
'Nothing' when that @local_path@ is already present, otherwise the new contents.
An empty list (@[]@ or blank) becomes just the block; a populated list gets the
block appended after a trailing newline. Existing entries are never reparsed.
-}
addEntryDedup :: String -> String -> String -> Maybe String
addEntryDedup existing localPath block
    | hasLocalPath existing localPath = Nothing
    | isEmptyList existing = Just block
    | otherwise = Just (ensureTrailingNewline existing ++ block)

{- | Replace the @short_title@ value of the entry whose @local_path@ matches,
leaving every other byte unchanged. 'Nothing' when no entry matches or the value
is already what was asked (so no write happens). Only the matched block's
@short_title@ line is rewritten; other entries, ordering, and @description@ stay
identical.
-}
setImageShortTitle :: String -> String -> String -> Maybe String
setImageShortTitle existing localPath newTitle =
    let (_, changed, revised) = foldl step (False, False, []) (lines existing)
     in if changed then Just (unlines (reverse revised)) else Nothing
  where
    step (inTarget, changed, acc) line =
        let inTarget' = blockMatch inTarget line
         in if inTarget' && isField "short_title" line
                then
                    let replacement = leadingWhitespace line ++ "short_title: " ++ singleQuoted newTitle
                     in if replacement == line
                            then (inTarget', changed, line : acc)
                            else (inTarget', True, replacement : acc)
                else (inTarget', changed, line : acc)
    blockMatch inTarget line
        | isItemStart line = fieldValueOn "local_path" line == Just localPath
        | otherwise = case fieldValueOn "local_path" line of
            Just value -> value == localPath
            Nothing -> inTarget

-- | The @(name, local_path)@ of each attachment entry, for the metadata panel (ADR-0049).
parseAttachments :: String -> [(String, String)]
parseAttachments contents = Maybe.mapMaybe blockToAttachment (splitBlocks (lines contents))
  where
    blockToAttachment block =
        let fields = Maybe.mapMaybe lineField block
         in case lookup "local_path" fields of
                Just localPath -> Just (Maybe.fromMaybe (fileName localPath) (lookup "name" fields), localPath)
                Nothing -> Nothing

-- | Append an attachment entry to the meta directory's @attachments.yaml@ (dedup, on-demand create).
appendAttachment :: FilePath -> AttachmentEntry -> IO ()
appendAttachment dir entry =
    appendEntryFile (attachmentsFile dir) (attachmentLocalPath entry) (renderAttachmentEntry entry)

-- | Append an inline-image entry to the meta directory's @images.yaml@ (dedup, on-demand create).
appendImage :: FilePath -> String -> String -> IO ()
appendImage dir localPath shortTitle =
    appendEntryFile (imagesFile dir) localPath (renderImageEntry localPath shortTitle)

{- | Sync the @short_title@ of an @images.yaml@ entry to a new value, writing only
when an entry matches and the value changes. Absent file or no match is a no-op.
-}
updateImageShortTitle :: FilePath -> String -> String -> IO ()
updateImageShortTitle dir localPath shortTitle = do
    let file = imagesFile dir
    exists <- Directory.doesFileExist file
    if not exists
        then pure ()
        else do
            existing <- readMetaFile file
            maybe (pure ()) (writeMetaFile file) (setImageShortTitle existing localPath shortTitle)

-- | The @(name, local_path)@ of each attachment recorded for the page, or @[]@ when none.
readAttachmentEntries :: FilePath -> IO [(String, String)]
readAttachmentEntries dir = do
    let file = attachmentsFile dir
    exists <- Directory.doesFileExist file
    if not exists
        then pure []
        else do
            contents <- readMetaFile file
            pure (parseAttachments contents)

-- Internal -----------------------------------------------------------------

-- | The @attachments.yaml@ file within a meta directory.
attachmentsFile :: FilePath -> FilePath
attachmentsFile dir = dir ++ "/attachments.yaml"

-- | The @images.yaml@ file within a meta directory.
imagesFile :: FilePath -> FilePath
imagesFile dir = dir ++ "/images.yaml"

{- | Read a list file (or treat an absent one as empty), apply the dedup append,
and write it back, creating the meta directory on demand.
-}
appendEntryFile :: FilePath -> String -> String -> IO ()
appendEntryFile file localPath block = do
    exists <- Directory.doesFileExist file
    existing <- if exists then readMetaFile file else pure "[]\n"
    case addEntryDedup existing localPath block of
        Nothing -> pure ()
        Just revised -> do
            Directory.createDirectoryIfMissing True (dirName file)
            writeMetaFile file revised

{- | Read and write a @.meta@ file as opaque (UTF-8) bytes -- never decoding, so multibyte characters in
attachment names survive verbatim (see 'Verso.App' for the same rationale on document bodies). The
@BS.readFile@ is strict, so reading then overwriting the same file is safe.
-}
readMetaFile :: FilePath -> IO String
readMetaFile file = fmap BS.unpack (BS.readFile file) -- whole-file: the YAML sidecar, a few hundred bytes

-- | Write a @.meta@ file as opaque (UTF-8) bytes (see 'readMetaFile').
writeMetaFile :: FilePath -> String -> IO ()
writeMetaFile file contents = BS.writeFile file (BS.pack contents)

-- | Whether the contents are the empty list (@[]@) or only whitespace.
isEmptyList :: String -> Bool
isEmptyList contents = let t = trim contents in t == "[]" || null t

-- | Whether any entry already carries this @local_path@.
hasLocalPath :: String -> String -> Bool
hasLocalPath contents localPath = any (\line -> fieldValueOn "local_path" line == Just localPath) (lines contents)

-- | Ensure a non-empty string ends in a newline; empty strings are unchanged.
ensureTrailingNewline :: String -> String
ensureTrailingNewline s
    | null s = s
    | last s == '\n' = s
    | otherwise = s ++ "\n"

-- | Split lines into top-level list-item blocks, dropping anything before the first item.
splitBlocks :: [String] -> [[String]]
splitBlocks ls =
    case dropWhile (not . isItemStart) ls of
        [] -> []
        (header : rest) ->
            let (body, more) = break isItemStart rest
             in (header : body) : splitBlocks more

-- | Whether a line begins a top-level list item (a @"- "@ at column zero).
isItemStart :: String -> Bool
isItemStart line = "- " `List.isPrefixOf` stripCarriageReturn line

{- | The @key: value@ on a line, ignoring leading whitespace and an optional @"- "@
item marker; 'Nothing' when the line is not a simple field. The value is unquoted.
-}
lineField :: String -> Maybe (String, String)
lineField raw =
    let stripped = dropWhile Char.isSpace (stripCarriageReturn raw)
        afterDash = if "- " `List.isPrefixOf` stripped then drop 2 stripped else stripped
     in case break (== ':') afterDash of
            (key, ':' : rest) | isSimpleKey key -> Just (key, unquote (trim rest))
            _ -> Nothing

-- | The unquoted value of a named field on a line, if present.
fieldValueOn :: String -> String -> Maybe String
fieldValueOn key line = case lineField line of
    Just (k, v) | k == key -> Just v
    _ -> Nothing

-- | Whether a line is the named field.
isField :: String -> String -> Bool
isField key line = case lineField line of
    Just (k, _) -> k == key
    Nothing -> False

-- | A simple YAML key here is a non-empty identifier with no spaces.
isSimpleKey :: String -> Bool
isSimpleKey key = not (null key) && notElem ' ' key

-- | A YAML single-quoted scalar, doubling any embedded single quote.
singleQuoted :: String -> String
singleQuoted s = "'" ++ concatMap escape s ++ "'"
  where
    escape '\'' = "''"
    escape c = [c]

-- | Unquote a single-quoted scalar (undoubling @''@); other values are returned as-is.
unquote :: String -> String
unquote value = case value of
    ('\'' : rest) | not (null rest) && last rest == '\'' -> undouble (init rest)
    _ -> value
  where
    undouble ('\'' : '\'' : xs) = '\'' : undouble xs
    undouble (c : xs) = c : undouble xs
    undouble [] = []

-- | The leading run of whitespace on a line.
leadingWhitespace :: String -> String
leadingWhitespace = takeWhile Char.isSpace

-- | Drop a trailing carriage return, if present (for CRLF-terminated lines).
stripCarriageReturn :: String -> String
stripCarriageReturn s = if not (null s) && last s == '\r' then init s else s

-- | Drop leading and trailing whitespace.
trim :: String -> String
trim = trimEnd . dropWhile Char.isSpace
  where
    trimEnd = reverse . dropWhile Char.isSpace . reverse

-- | The non-empty @/@-separated segments of a tree path.
pathSegments :: String -> [String]
pathSegments path = filter (not . null) (splitOnSlash path)

-- | Split a string on @/@, keeping empty segments.
splitOnSlash :: String -> [String]
splitOnSlash s = case break (== '/') s of
    (a, []) -> [a]
    (a, _ : rest) -> a : splitOnSlash rest

-- | The final path segment (filename).
fileName :: FilePath -> String
fileName = reverse . takeWhile (/= '/') . reverse

-- | The directory part of a path (everything up to the last @/@), or @"."@ if none.
dirName :: FilePath -> FilePath
dirName p = case break (== '/') (reverse p) of
    (_, '/' : rest) -> reverse rest
    (_, _) -> "."

-- | Drop a trailing @.md@ extension from a filename, if present.
dropMarkdownExtension :: String -> String
dropMarkdownExtension name = if ".md" `List.isSuffixOf` name then take (length name - 3) name else name
