{- | The trash provenance manifest (RFC-0028, phase 2). A delete moves a page or
section out of the corpus into a trash entry rather than destroying it; the entry's
manifest records where it came from so 'restore' is a uniform inverse: each trashed
item carries its stored name (inside the entry), whether it is a directory, and its
origin tree path, so restore moves every item back to exactly where it was.

The manifest render/parse is pure and round-trips. The format is a simple line-based
one (not nested JSON) so it parses without a JSON object parser: a @path@/@kind@/@seq@
header then one @item:@ line per stored file or directory.
-}
module Verso.Trash (
    TrashItem (..),
    Manifest (..),
    renderManifest,
    parseManifest,
    readManifest,
    writeManifest,
    moveIntoTrash,
    moveDirIntoTrash,
    restoreItem,
    targetOccupied,
    listTrash,
    deleteTrashEntry,
) where

import qualified Control.Monad as Monad
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Stream as Stream
import qualified MicroHttp.Utf8 as Utf8
import qualified System.Directory as Directory
import qualified Verso.TreePath as TreePath

-- | One stored file or directory in a trash entry: its name inside the entry, whether it is a directory, and its origin tree path.
data TrashItem = TrashItem
    { itemStored :: String
    , itemIsDir :: Bool
    , itemOrigin :: String
    }
    deriving (Eq, Show)

{- | A trash entry's provenance: the deleted item's original tree path, its kind
(@page@/@section@), the originating operation-log @seq@, and the stored items to
restore.
-}
data Manifest = Manifest
    { manPath :: String
    , manKind :: String
    , manSeq :: Int
    , manListing :: Maybe String
    , manItems :: [TrashItem]
    }
    deriving (Eq, Show)

-- | Renders a manifest as its line-based text (header lines, optional listing line, then one @item:@ line each).
renderManifest :: Manifest -> String
renderManifest manifest =
    unlines
        ( ["path: " ++ manPath manifest, "kind: " ++ manKind manifest, "seq: " ++ show (manSeq manifest)]
            ++ maybe [] (\listing -> ["listing: " ++ listing]) (manListing manifest)
            ++ map renderItem (manItems manifest)
        )
  where
    renderItem item =
        "item: " ++ itemStored item ++ " " ++ (if itemIsDir item then "dir" else "file") ++ " " ++ itemOrigin item

-- | Parses a manifest held whole, or 'Nothing' when a required header is missing or malformed.
parseManifest :: String -> Maybe Manifest
parseManifest = finishManifest . List.foldl' manifestLine emptyDraft . lines

{- | Reads an entry's manifest file, one line at a time, decoding UTF-8 (RFC-0043):
'Nothing' when the file is absent, unreadable, or not a valid manifest.
-}
readManifest :: FilePath -> IO (Maybe Manifest)
readManifest entryDir = do
    let file = entryDir ++ "/manifest"
    exists <- Directory.doesFileExist file
    if not exists
        then pure Nothing
        else either (const Nothing) finishManifest <$> Stream.foldFileTextLines (\draft line -> pure (manifestLine draft line)) emptyDraft file

-- | Writes an entry's manifest file as UTF-8, one line at a time.
writeManifest :: FilePath -> Manifest -> IO ()
writeManifest entryDir manifest = do
    _ <- Stream.writeFileLines (entryDir ++ "/manifest") (map Utf8.encodeText (lines (renderManifest manifest)))
    pure ()

{- | The manifest as it accumulates line by line: the first occurrence of each
header wins, as the whole-text parser's @optField@ did, and items keep file order
(accumulated in reverse).
-}
data Draft = Draft
    { draftPath :: Maybe String
    , draftKind :: Maybe String
    , draftSeq :: Maybe String
    , draftListing :: Maybe String
    , draftItems :: [TrashItem]
    }

emptyDraft :: Draft
emptyDraft = Draft Nothing Nothing Nothing Nothing []

-- | Folds one manifest line into the draft.
manifestLine :: Draft -> String -> Draft
manifestLine draft line
    | Just value <- field "path: " = draft{draftPath = firstOf (draftPath draft) value}
    | Just value <- field "kind: " = draft{draftKind = firstOf (draftKind draft) value}
    | Just value <- field "seq: " = draft{draftSeq = firstOf (draftSeq draft) value}
    | Just value <- field "listing: " = draft{draftListing = firstOf (draftListing draft) value}
    | Just item <- parseItem line = draft{draftItems = item : draftItems draft}
    | otherwise = draft
  where
    field prefix = List.stripPrefix prefix line
    firstOf (Just kept) _ = Just kept
    firstOf Nothing value = Just value

-- | The manifest from a completed draft, or 'Nothing' when a required header is missing or malformed.
finishManifest :: Draft -> Maybe Manifest
finishManifest draft = do
    pathLine <- draftPath draft
    kindLine <- draftKind draft
    seqVal <- draftSeq draft >>= readInt
    pure
        Manifest
            { manPath = pathLine
            , manKind = kindLine
            , manSeq = seqVal
            , manListing = draftListing draft
            , manItems = reverse (draftItems draft)
            }

-- | Parses one @item: <stored> <file|dir> <origin>@ line.
parseItem :: String -> Maybe TrashItem
parseItem line
    | not ("item: " `List.isPrefixOf` line) = Nothing
    | otherwise = case words (drop (length "item: ") line) of
        (stored : typ : originWords@(_ : _)) ->
            Just (TrashItem stored (typ == "dir") (unwords originWords))
        _ -> Nothing

-- | Parses a non-negative integer, or 'Nothing'.
readInt :: String -> Maybe Int
readInt s = case reads s of
    [(n, "")] -> Just n
    _ -> Nothing

-- | Moves one tree path into a trash entry under the given stored name (best-effort), yielding its manifest item.
moveIntoTrash :: FilePath -> FilePath -> String -> TreePath.TreePath -> Bool -> IO (Maybe TrashItem)
moveIntoTrash root entryDir stored origin isDir = do
    outcome <- FileSystem.renamePath (TreePath.resolve root origin) (entryDir ++ "/" ++ stored)
    pure
        ( either
            (const Nothing)
            (const (Just (TrashItem stored isDir (TreePath.render origin))))
            outcome
        )

-- | As 'moveIntoTrash' for a directory that may be absent (a page with no sidecar meta dir).
moveDirIntoTrash :: FilePath -> FilePath -> String -> TreePath.TreePath -> IO (Maybe TrashItem)
moveDirIntoTrash root entryDir stored origin = do
    exists <- Directory.doesDirectoryExist (TreePath.resolve root origin)
    if not exists then pure Nothing else moveIntoTrash root entryDir stored origin True

-- | Moves one trashed item back to its origin tree path (creating parent directories); an item whose origin does not parse is left in the entry.
restoreItem :: FilePath -> FilePath -> TrashItem -> IO ()
restoreItem root entryDir item =
    case TreePath.parse (itemOrigin item) of
        Nothing -> pure ()
        Just dest -> do
            Directory.createDirectoryIfMissing True (TreePath.resolve root (TreePath.parent dest))
            Monad.void (FileSystem.renamePath (entryDir ++ "/" ++ itemStored item) (TreePath.resolve root dest))

-- | Whether a tree path is currently occupied (a page's file, a section's directory).
targetOccupied :: FilePath -> TreePath.TreePath -> String -> IO Bool
targetOccupied root path kind =
    if kind == "section" then Directory.doesDirectoryExist fs else Directory.doesFileExist fs
  where
    fs = TreePath.resolve root path

{- | Lists the trash entries (RFC-0028) as @(id, originalPath, kind)@, newest-id last,
reading each entry's manifest. Entries without a valid id or a readable manifest are skipped.
-}
listTrash :: FilePath -> IO [(String, String, String)]
listTrash trashRoot = do
    exists <- Directory.doesDirectoryExist trashRoot
    if not exists
        then pure []
        else do
            names <- Directory.listDirectory trashRoot
            entries <- mapM entryFor (Maybe.mapMaybe TreePath.parseTrashId names)
            pure (Maybe.catMaybes entries)
  where
    entryFor trashId = do
        let entryDir = TreePath.trashEntryDir trashRoot trashId
        hasManifest <- Directory.doesFileExist (entryDir ++ "/manifest")
        if not hasManifest
            then pure Nothing
            else do
                parsed <- readManifest entryDir
                pure (fmap (\m -> (TreePath.renderTrashId trashId, manPath m, manKind m)) parsed)

{- | Permanently removes a trash entry (its directory and everything stored in
it). Returns whether the entry existed.
-}
deleteTrashEntry :: FilePath -> TreePath.TrashId -> IO Bool
deleteTrashEntry trashRoot trashId = do
    let entryDir = TreePath.trashEntryDir trashRoot trashId
    exists <- Directory.doesDirectoryExist entryDir
    if not exists
        then pure False
        else do
            removeTree entryDir
            pure True

-- | Recursively removes a directory tree (MicroHs's System.Directory has no removeDirectoryRecursive).
removeTree :: FilePath -> IO ()
removeTree dir = do
    names <- Directory.listDirectory dir
    Monad.forM_ names $ \name -> do
        let child = dir ++ "/" ++ name
        isDir <- Directory.doesDirectoryExist child
        if isDir then removeTree child else Monad.void (FileSystem.removeFilePath child)
    Monad.void (FileSystem.removeEmptyDir dir)
