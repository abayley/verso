{- | In-server section move (RFC-0027, phase 2): relocate a section folder to a new
parent and/or slug, preserving link integrity. The pure cores do the work --
'MicroHttp.DocumentLinks.planMoveRewrites' computes the link rewrites across the
whole tree, 'MicroHttp.DocumentListing' relocates the parent @index.md@ listing card
-- and this module supplies the IO: enumerating the tree's pages, the refusals
(root, cycle, collision), the @rename(2)@, and the writes.

Every operation is preview-then-confirm (RFC-0027 safety): with @confirm@ 'False' it
returns the impact ('MovePlan') without writing; with 'True' it applies the move and
returns the same plan marked applied. A move is best-effort transactional: the
rewrites are computed up front against the pre-move tree, then the directory is
renamed and the rewritten pages and listings are written.
-}
module MicroHttp.TreeMove (
    MovePlan (..),
    moveSection,
    movePlanJson,
) where

import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as BS
import Data.List (intercalate, isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import MicroHttp.DocumentLinks (pathSegmentsOf, planMoveRewrites, relocatePath)
import MicroHttp.DocumentListing (addListingEntry, removeListingEntry)
import MicroHttp.FileOps (renamePath)
import MicroHttp.Static (resolveStaticPath)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)

{- | The impact of a section move: the source and destination tree paths, the tree
paths (final locations) of the pages whose links change, and whether it was applied
(or is a preview).
-}
data MovePlan = MovePlan
    { planFrom :: String
    , planTo :: String
    , planChanged :: [String]
    , planApplied :: Bool
    }
    deriving (Eq, Show)

{- | Moves the section at @srcRel@ under @destParentRel@ with slug @slug@ (the
source's own slug when @slug@ is empty), previewing when @confirm@ is 'False' and
applying when 'True'. Returns 'Left' with a reason on refusal (the root, a cycle,
an unsafe path, a missing destination parent, or a destination collision).
-}
moveSection :: FilePath -> String -> String -> String -> Bool -> IO (Either String MovePlan)
moveSection root rawSrcRel rawDestParentRel rawSlug confirm
    | null srcSegs = pure (Left "cannot move the root")
    | otherwise =
        case (resolveStaticPath root srcSegs, resolveStaticPath root newSegs, resolveStaticPath root destParentSegs) of
            (Nothing, _, _) -> pure (Left "unsafe source path")
            (_, Nothing, _) -> pure (Left "unsafe destination slug")
            (_, _, Nothing) -> pure (Left "unsafe destination path")
            (Just srcFs, Just newFs, Just destParentFs)
                | srcRel == newPrefix -> pure (Left "destination is the source")
                | (srcRel ++ "/") `isPrefixOf` newPrefix -> pure (Left "cannot move a section into itself")
                | otherwise -> withChecks srcFs newFs destParentFs
  where
    -- Canonicalise the raw request paths (drop empty/doubled/edge slashes) so the
    -- string cycle checks and the listing-match target align with resolved paths.
    srcSegs = pathSegmentsOf rawSrcRel
    destParentSegs = pathSegmentsOf rawDestParentRel
    srcRel = intercalate "/" srcSegs
    destParentRel = intercalate "/" destParentSegs
    slug = if null rawSlug then last srcSegs else rawSlug
    newPrefix = joinRel destParentRel slug
    newSegs = pathSegmentsOf newPrefix

    withChecks srcFs newFs destParentFs = do
        srcIsDir <- doesDirectoryExist srcFs
        destParentIsDir <- doesDirectoryExist destParentFs
        collidesDir <- doesDirectoryExist newFs
        collidesFile <- doesFileExist newFs
        if not srcIsDir
            then pure (Left "source is not a section")
            else
                if not destParentIsDir
                    then pure (Left "destination parent not found")
                    else
                        if collidesDir || collidesFile
                            then pure (Left "destination already exists")
                            else runMove srcFs newFs

    runMove srcFs newFs = do
        pages <- enumerateMarkdown root ""
        let srcParentRel = parentRel srcRel
            srcIndexRel = indexRel srcParentRel
            destIndexRel = indexRel destParentRel
            excluded = [srcIndexRel, destIndexRel]
            rewritePages = [(p, b) | (p, b) <- pages, p `notElem` excluded]
            rewrites = planMoveRewrites (srcRel, newPrefix) rewritePages
            changed = [fromMaybe p (relocatePath srcRel newPrefix p) | (p, _) <- rewrites]
        if not confirm
            then pure (Right (MovePlan srcRel newPrefix changed False))
            else do
                ok <- renamePath srcFs newFs
                if not ok
                    then pure (Left "rename failed")
                    else do
                        forM_ rewrites $ \(oldPath, newText) ->
                            writeRel root (fromMaybe oldPath (relocatePath srcRel newPrefix oldPath)) newText
                        relocateListing root srcRel srcParentRel destParentRel newPrefix
                        pure (Right (MovePlan srcRel newPrefix changed True))

{- | Moves the moved section's listing card from the source parent's index.md to the
destination parent's, repointing its link to the destination. When the source had no
card, a minimal entry is synthesised from the section's index.md @name@.
-}
relocateListing :: FilePath -> String -> String -> String -> String -> IO ()
relocateListing root srcRel srcParentRel destParentRel newPrefix = do
    srcText <- readRel root srcIndexRel
    removed <- case srcText of
        Just t ->
            let (t', r) = removeListingEntry srcParentRel (srcRel ++ "/index.md") t
             in writeRel root srcIndexRel t' >> pure r
        Nothing -> pure Nothing
    title <- frontmatterNameOf newSectionIndexFs
    let entry = fromMaybe (synthEntry title) removed
    destBase <- fmap (fromMaybe "") (readRel root destIndexRel)
    writeRel root destIndexRel (addListingEntry destParentRel (newPrefix ++ "/index.md") entry destBase)
  where
    srcIndexRel = indexRel srcParentRel
    destIndexRel = indexRel destParentRel
    newSectionIndexFs = fromMaybe "" (resolveStaticPath root (pathSegmentsOf (newPrefix ++ "/index.md")))
    slug = last (pathSegmentsOf newPrefix)
    synthEntry t = "- [" ++ t ++ "](./" ++ slug ++ "/index.md)"

-- | Reads every @.md@ page beneath the tree as @(treeRelPath, body)@, skipping dot-entries and @assets@/@meta@ folders.
enumerateMarkdown :: FilePath -> String -> IO [(String, String)]
enumerateMarkdown root rel = do
    let dirFs = fromMaybe root (resolveStaticPath root (pathSegmentsOf rel))
    names <- listDirectory dirFs
    fmap concat (mapM (collect dirFs) names)
  where
    collect dirFs name
        | isDot name = pure []
        | otherwise = do
            let childRel = joinRel rel name
                childFs = dirFs ++ "/" ++ name
            isDir <- doesDirectoryExist childFs
            if isDir
                then if name == "assets" || name == "meta" then pure [] else enumerateMarkdown root childRel
                else
                    if ".md" `isSuffixOf` name
                        then do
                            body <- fmap BS.unpack (BS.readFile childFs)
                            pure [(childRel, body)]
                        else pure []
    isDot ('.' : _) = True
    isDot _ = False

-- | Reads a tree-relative file, or 'Nothing' when it is absent or its path is unsafe.
readRel :: FilePath -> String -> IO (Maybe String)
readRel root rel =
    case resolveStaticPath root (pathSegmentsOf rel) of
        Nothing -> pure Nothing
        Just fs -> do
            exists <- doesFileExist fs
            if exists then fmap (Just . BS.unpack) (BS.readFile fs) else pure Nothing

-- | Writes a tree-relative file (creating parent directories), ignoring an unsafe path.
writeRel :: FilePath -> String -> String -> IO ()
writeRel root rel content =
    case resolveStaticPath root (pathSegmentsOf rel) of
        Nothing -> pure ()
        Just fs -> do
            createDirectoryIfMissing True (parentDir fs)
            BS.writeFile fs (BS.pack content)
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

-- | The frontmatter @name@ of an index.md (for a synthesised listing entry), or a fallback.
frontmatterNameOf :: FilePath -> IO String
frontmatterNameOf fs = do
    exists <- doesFileExist fs
    if not exists
        then pure "Untitled"
        else fmap (fromMaybe "Untitled" . frontmatterName . BS.unpack) (BS.readFile fs)

-- | Extracts the @name:@ scalar from a leading @---@ frontmatter block.
frontmatterName :: String -> Maybe String
frontmatterName text = case lines text of
    ("---" : rest) -> lookupName (takeWhile (/= "---") rest)
    _ -> Nothing
  where
    lookupName [] = Nothing
    lookupName (l : ls)
        | "name:" `isPrefixOf` l = Just (unquote (trim (drop (length "name:") l)))
        | otherwise = lookupName ls
    trim = dropWhile (== ' ')
    unquote s
        | length s >= 2 && head s == '"' && last s == '"' = init (drop 1 s)
        | otherwise = s

-- | The parent tree path of a tree path (its segments minus the last; @""@ at the root).
parentRel :: String -> String
parentRel rel = intercalate "/" (initOrEmpty (pathSegmentsOf rel))
  where
    initOrEmpty [] = []
    initOrEmpty xs = init xs

-- | The index.md tree path of a folder path (@index.md@ at the root).
indexRel :: String -> String
indexRel "" = "index.md"
indexRel r = r ++ "/index.md"

-- | Joins a parent tree path and a child segment (the segment alone at the root).
joinRel :: String -> String -> String
joinRel "" s = s
joinRel p s = p ++ "/" ++ s

-- | A move plan as JSON @{"from","to","changed":[...],"applied":bool}@.
movePlanJson :: MovePlan -> String
movePlanJson plan =
    "{\"from\":"
        ++ jsonStr (planFrom plan)
        ++ ",\"to\":"
        ++ jsonStr (planTo plan)
        ++ ",\"changed\":["
        ++ intercalate "," (map jsonStr (planChanged plan))
        ++ "],\"applied\":"
        ++ (if planApplied plan then "true" else "false")
        ++ "}"

-- | A minimal JSON string literal (escaping quotes, backslashes, and control characters).
jsonStr :: String -> String
jsonStr s = "\"" ++ concatMap esc s ++ "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c = [c]
