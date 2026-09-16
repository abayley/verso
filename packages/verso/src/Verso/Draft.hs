{- | The draft staging store for RFC-0032. While an author edits a page, autosave
writes the page's markdown here -- under a draft root /outside/ the document tree
-- rather than to the live page. Publishing promotes the draft into the tree and
clears it; navigating away leaves it in place to be resumed later.

A draft mirrors the page's tree-relative path under the draft root
(@\<draftRoot\>/\<treePath\>@), so each page has at most one draft and lookups are
a direct path. Because the staging root is outside the tree, drafts are never
served, never walked by the link index, and never appear in git status.

The page is named by its validated 'TreePath.TreePath', so this module performs
no path-safety checks of its own -- the same contract as 'MicroHttp.FileSystem'.
-}
module Verso.Draft (
    draftFsPath,
    writeDraft,
    hasDraft,
    deleteDraft,
) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified System.Directory as Directory
import qualified Verso.TreePath as TreePath

-- | The filesystem path of a page's draft: the tree-relative path under the draft root.
draftFsPath :: FilePath -> TreePath.TreePath -> FilePath
draftFsPath = TreePath.resolve

-- | Writes (creating or overwriting) a page's draft, creating parent directories as needed.
writeDraft :: FilePath -> TreePath.TreePath -> BS.ByteString -> IO ()
writeDraft draftRoot page content = do
    Directory.createDirectoryIfMissing True (draftFsPath draftRoot (TreePath.parent page))
    BS.writeFile (draftFsPath draftRoot page) content

-- | Whether a draft is currently staged for the page.
hasDraft :: FilePath -> TreePath.TreePath -> IO Bool
hasDraft draftRoot page = Directory.doesFileExist (draftFsPath draftRoot page)

-- | Removes a page's draft if present (a no-op when there is none), e.g. after publishing or discarding.
deleteDraft :: FilePath -> TreePath.TreePath -> IO ()
deleteDraft draftRoot page = do
    let path = draftFsPath draftRoot page
    exists <- Directory.doesFileExist path
    Monad.when exists (Directory.removeFile path)
