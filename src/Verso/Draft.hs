{- | The draft staging store for RFC-0032. While an author edits a page, autosave
writes the page's markdown here -- under a draft root /outside/ the document tree
-- rather than to the live page. Publishing promotes the draft into the tree and
clears it; navigating away leaves it in place to be resumed later.

A draft mirrors the page's tree-relative path under the draft root
(@\<draftRoot\>/\<treePath\>@), so each page has at most one draft and lookups are
a direct path. Because the staging root is outside the tree, drafts are never
served, never walked by the link index, and never appear in git status.

Callers pass an already-validated tree-relative path (the tree handlers validate
via 'MicroHttp.Static.resolveStaticPath' before staging), so this module performs
no path-safety checks of its own -- the same contract as 'MicroHttp.FileSystem'.
-}
module Verso.Draft (
    draftFsPath,
    writeDraft,
    readDraft,
    hasDraft,
    deleteDraft,
) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified System.Directory as Directory

-- | The filesystem path of a page's draft: the tree-relative path under the draft root.
draftFsPath :: FilePath -> String -> FilePath
draftFsPath draftRoot treePath = draftRoot ++ "/" ++ treePath

-- | Writes (creating or overwriting) a page's draft, creating parent directories as needed.
writeDraft :: FilePath -> String -> BS.ByteString -> IO ()
writeDraft draftRoot treePath content = do
    let path = draftFsPath draftRoot treePath
    Directory.createDirectoryIfMissing True (parentDir path)
    BS.writeFile path content

-- | Reads a page's draft, or 'Nothing' when no draft is staged for it.
readDraft :: FilePath -> String -> IO (Maybe BS.ByteString)
readDraft draftRoot treePath = do
    let path = draftFsPath draftRoot treePath
    exists <- Directory.doesFileExist path
    if exists
        then fmap Just (BS.readFile path)
        else pure Nothing

-- | Whether a draft is currently staged for the page.
hasDraft :: FilePath -> String -> IO Bool
hasDraft draftRoot treePath = Directory.doesFileExist (draftFsPath draftRoot treePath)

-- | Removes a page's draft if present (a no-op when there is none), e.g. after publishing or discarding.
deleteDraft :: FilePath -> String -> IO ()
deleteDraft draftRoot treePath = do
    let path = draftFsPath draftRoot treePath
    exists <- Directory.doesFileExist path
    Monad.when exists (Directory.removeFile path)

-- | The parent directory of a path (everything up to and including the last @/@).
parentDir :: FilePath -> FilePath
parentDir = reverse . dropWhile (/= '/') . reverse
