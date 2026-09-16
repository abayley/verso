{- | The document tree's layout, in one place (RFC-0044). A 'TreePath' is a
validated tree-relative path: its segments are non-empty and free of @.@, @..@,
separators and NUL ('Static.safeComponent'), so a value of the type can be
resolved under a root without a further check. Everything the application
derives from a path -- its kind (page or section), parent, slug, section
@index.md@, meta directory, peer @assets/@ folder and served filesystem path --
is a function here, and nowhere else. A 'TrashId' is likewise a validated trash
entry name, so every trash path is built from a checked id.

Paths are canonicalised on parse (empty, doubled and edge slashes dropped), so
'render' of two paths naming the same tree node is the same string.
-}
module Verso.TreePath (
    TreePath,
    Kind (..),
    parse,
    root,
    render,
    segments,
    isRoot,
    kind,
    name,
    slug,
    parent,
    child,
    append,
    within,
    sectionIndex,
    metaDirectory,
    peerAssets,
    resolve,
    TrashId,
    parseTrashId,
    trashIdForSeq,
    renderTrashId,
    trashEntryDir,
) where

import qualified Data.Char as Char
import qualified Data.List as List
import qualified MicroHttp.Static as Static

-- | A validated tree-relative path; the root is the empty segment list.
newtype TreePath = TreePath [String]
    deriving (Eq, Ord, Show)

-- | What a tree path names: a Markdown page or a section folder.
data Kind = Page | Section
    deriving (Eq, Show)

-- | The document tree itself.
root :: TreePath
root = TreePath []

{- | Parses a raw tree-relative path: split on @/@, drop empty segments, and
accept only if every remaining segment is safe. @""@ and @"/"@ are the root.
-}
parse :: String -> Maybe TreePath
parse raw
    | all Static.safeComponent segs = Just (TreePath segs)
    | otherwise = Nothing
  where
    segs = filter (not . null) (splitOnSlash raw)

-- | The path as a @/@-joined string; @""@ for the root.
render :: TreePath -> String
render (TreePath segs) = List.intercalate "/" segs

-- | The validated segments.
segments :: TreePath -> [String]
segments (TreePath segs) = segs

-- | Whether the path is the tree root.
isRoot :: TreePath -> Bool
isRoot (TreePath segs) = null segs

-- | A page when the last segment ends in @.md@, otherwise a section (the root is a section).
kind :: TreePath -> Kind
kind path
    | markdownSuffix `List.isSuffixOf` name path = Page
    | otherwise = Section

-- | The last segment; @""@ for the root.
name :: TreePath -> String
name (TreePath []) = ""
name (TreePath segs) = last segs

-- | The name without its @.md@ for a page; the name itself for a section.
slug :: TreePath -> String
slug path = case kind path of
    Page -> take (length n - length markdownSuffix) n
    Section -> n
  where
    n = name path

-- | The enclosing section: the segments minus the last. The root's parent is the root.
parent :: TreePath -> TreePath
parent (TreePath []) = root
parent (TreePath segs) = TreePath (init segs)

-- | One safe segment appended, or 'Nothing' if the name is not a safe segment.
child :: TreePath -> String -> Maybe TreePath
child (TreePath segs) childName
    | Static.safeComponent childName = Just (TreePath (segs ++ [childName]))
    | otherwise = Nothing

{- | A relative path (one or more segments, as a page body or a sidecar names an
asset) parsed and appended, or 'Nothing' if any segment is unsafe.
-}
append :: TreePath -> String -> Maybe TreePath
append (TreePath segs) relative = fmap (\(TreePath more) -> TreePath (segs ++ more)) (parse relative)

-- | Whether the first path is the second or lies beneath it.
within :: TreePath -> TreePath -> Bool
within (TreePath segs) (TreePath ancestor) = ancestor `List.isPrefixOf` segs

-- | A section's landing page, its @index.md@.
sectionIndex :: TreePath -> TreePath
sectionIndex (TreePath segs) = TreePath (segs ++ ["index.md"])

-- | A page's meta directory: @\<parent>/meta/\<base>.meta@, where base is the name without @.md@.
metaDirectory :: TreePath -> TreePath
metaDirectory path = TreePath (segments (parent path) ++ ["meta", slug path ++ ".meta"])

-- | A page's peer assets folder, the @assets/@ beside it.
peerAssets :: TreePath -> TreePath
peerAssets path = TreePath (segments (parent path) ++ ["assets"])

-- | The served filesystem path of a tree path under a root; total, because the segments are validated.
resolve :: FilePath -> TreePath -> FilePath
resolve treeRoot (TreePath []) = treeRoot
resolve treeRoot (TreePath segs) = treeRoot ++ "/" ++ List.intercalate "/" segs

-- | A validated trash entry name: non-empty and all digits, so it can never be path-like.
newtype TrashId = TrashId String
    deriving (Eq, Ord, Show)

-- | Parses a trash entry name, refusing anything that is not a non-empty run of digits.
parseTrashId :: String -> Maybe TrashId
parseTrashId raw
    | not (null raw) && all Char.isDigit raw = Just (TrashId raw)
    | otherwise = Nothing

-- | The trash id a delete takes from its operation-log sequence number; 'Nothing' for a negative one.
trashIdForSeq :: Int -> Maybe TrashId
trashIdForSeq = parseTrashId . show

-- | The entry name as a string.
renderTrashId :: TrashId -> String
renderTrashId (TrashId raw) = raw

-- | A trash entry's directory under the trash root.
trashEntryDir :: FilePath -> TrashId -> FilePath
trashEntryDir trashRoot (TrashId raw) = trashRoot ++ "/" ++ raw

-- | The Markdown page extension.
markdownSuffix :: String
markdownSuffix = ".md"

-- | Split on @/@, keeping empty segments for the caller to drop.
splitOnSlash :: String -> [String]
splitOnSlash s = case break (== '/') s of
    (seg, '/' : rest) -> seg : splitOnSlash rest
    (seg, _) -> [seg]
