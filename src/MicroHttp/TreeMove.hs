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
    movePage,
    movePlanJson,
) where

import Control.Monad (forM, forM_, void, when)
import qualified Data.ByteString.Char8 as BS
import Data.Char (isSpace)
import Data.List (intercalate, isPrefixOf, isSuffixOf, nub, stripPrefix)
import Data.Maybe (fromMaybe, maybeToList)
import MicroHttp.DocumentLinks (
    AssetClass (..),
    assetNamesIn,
    classifyAssets,
    pathSegmentsOf,
    planMoveRewrites,
    planPageMove,
    relocatePath,
 )
import MicroHttp.DocumentListing (addListingEntry, removeListingEntry)
import MicroHttp.DocumentMeta (metaDirectoryFor)
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

{- | Relocates a member's listing entry from the source parent's index.md to the
destination parent's, repointing its link from @oldTarget@ to @newTarget@. When the
source had no entry, the synthesised fallback is used. Shared by section move (a grid
card, @newTarget@ ending @/index.md@) and page move (a flat bullet).
-}
relocateEntry :: FilePath -> String -> String -> String -> String -> String -> IO ()
relocateEntry root srcParentRel destParentRel oldTarget newTarget synth = do
    srcText <- readRel root srcIndexRel
    removed <- case srcText of
        Just t ->
            let (t', r) = removeListingEntry srcParentRel oldTarget t
             in writeRel root srcIndexRel t' >> pure r
        Nothing -> pure Nothing
    let entry = fromMaybe synth removed
    destBase <- fmap (fromMaybe "") (readRel root destIndexRel)
    writeRel root destIndexRel (addListingEntry destParentRel newTarget entry destBase)
  where
    srcIndexRel = indexRel srcParentRel
    destIndexRel = indexRel destParentRel

-- | Relocates the moved section's listing card (a grid card linking the section's index.md).
relocateListing :: FilePath -> String -> String -> String -> String -> IO ()
relocateListing root srcRel srcParentRel destParentRel newPrefix = do
    title <- frontmatterNameOf newSectionIndexFs
    relocateEntry
        root
        srcParentRel
        destParentRel
        (srcRel ++ "/index.md")
        (newPrefix ++ "/index.md")
        ("- [" ++ title ++ "](./" ++ last (pathSegmentsOf newPrefix) ++ "/index.md)")
  where
    newSectionIndexFs = fromMaybe "" (resolveStaticPath root (pathSegmentsOf (newPrefix ++ "/index.md")))

{- | Moves the page at @srcRel@ (a @.md@ tree path) under @destParentRel@ with slug
@slug@ (the source's own base name when empty), previewing when @confirm@ is 'False'.
A same-folder change is a rename; a cross-folder move additionally co-moves the
sidecar meta directory and runs the asset shared/exclusive analysis (ADR-062),
relocating exclusive assets and copying shared ones. Refuses the root-of-page
edge cases: an unsafe path, a missing source/destination parent, a destination
collision, a no-op (destination is the source), or a destination asset name that
already holds different content.
-}
movePage :: FilePath -> String -> String -> String -> Bool -> IO (Either String MovePlan)
movePage root rawSrcRel rawDestParentRel rawSlug confirm
    | not (".md" `isSuffixOf` srcRel) = pure (Left "source is not a page")
    | otherwise =
        case (resolveStaticPath root srcSegs, resolveStaticPath root newSegs, resolveStaticPath root destParentSegs) of
            (Nothing, _, _) -> pure (Left "unsafe source path")
            (_, Nothing, _) -> pure (Left "unsafe destination slug")
            (_, _, Nothing) -> pure (Left "unsafe destination path")
            (Just srcFs, Just newFs, Just destParentFs)
                | srcRel == newPath -> pure (Left "destination is the source")
                | otherwise -> withChecks srcFs newFs destParentFs
  where
    srcSegs = pathSegmentsOf rawSrcRel
    srcRel = intercalate "/" srcSegs
    destParentSegs = pathSegmentsOf rawDestParentRel
    destParentRel = intercalate "/" destParentSegs
    base = dropDotMd (last srcSegs)
    slug = if null rawSlug then base else rawSlug
    newPath = joinRel destParentRel (slug ++ ".md")
    newSegs = pathSegmentsOf newPath
    srcDir = parentRel srcRel

    withChecks srcFs newFs destParentFs = do
        srcIsFile <- doesFileExist srcFs
        destParentIsDir <- doesDirectoryExist destParentFs
        collides <- doesFileExist newFs
        if not srcIsFile
            then pure (Left "source page not found")
            else
                if not destParentIsDir
                    then pure (Left "destination parent not found")
                    else
                        if collides
                            then pure (Left "destination already exists")
                            else runPageMove srcFs newFs

    runPageMove srcFs newFs = do
        let crossFolder = srcDir /= destParentRel
            srcParentIndexRel = indexRel srcDir
            destParentIndexRel = indexRel destParentRel
            excluded = [srcParentIndexRel, destParentIndexRel]
        assets <- if crossFolder then classifyMovingAssets root srcRel srcDir else pure []
        conflicts <- assetConflicts root srcDir destParentRel (map fst assets)
        if not (null conflicts)
            then pure (Left ("destination asset already exists with different content: " ++ intercalate ", " conflicts))
            else do
                pages <- enumerateMarkdown root ""
                let rewritePages = filter ((`notElem` excluded) . fst) pages
                    rewrites = planPageMove (srcRel, newPath) rewritePages
                    changed = map fst rewrites
                if not confirm
                    then pure (Right (MovePlan srcRel newPath changed False))
                    else do
                        -- Rename the .md first: it is the cheapest op and the only one
                        -- whose failure has no clean recovery, so on failure nothing
                        -- destructive has happened yet (the assets/meta still co-move
                        -- from their unchanged source locations afterwards).
                        ok <- renamePath srcFs newFs
                        if not ok
                            then pure (Left "rename failed")
                            else do
                                forM_ assets (relocateOrCopyAsset root srcDir destParentRel)
                                relocateMeta root srcRel newPath
                                forM_ rewrites (uncurry (writeRel root))
                                title <- frontmatterNameOf newFs
                                relocateEntry root srcDir destParentRel srcRel newPath ("- [" ++ title ++ "](./" ++ slug ++ ".md)")
                                pure (Right (MovePlan srcRel newPath changed True))

-- | Drops a trailing @.md@ from a filename.
dropDotMd :: String -> String
dropDotMd name
    | ".md" `isSuffixOf` name = take (length name - length ".md") name
    | otherwise = name

-- | The shared/exclusive classification of the moving page's assets against its source-folder peers (ADR-062).
classifyMovingAssets :: FilePath -> String -> String -> IO [(String, AssetClass)]
classifyMovingAssets root srcRel srcDir = do
    movingBody <- fmap (fromMaybe "") (readRel root srcRel)
    movingSidecar <- sidecarAssetNames root srcRel
    let movingAssets = nub (assetNamesIn movingBody ++ movingSidecar)
    peers <- siblingPages root srcDir srcRel
    peerRefs <- forM peers $ \peer -> do
        body <- fmap (fromMaybe "") (readRel root peer)
        sidecar <- sidecarAssetNames root peer
        pure (nub (assetNamesIn body ++ sidecar))
    pure (classifyAssets movingAssets peerRefs)

-- | The @.md@ pages directly in a folder (non-recursive), excluding the named page.
siblingPages :: FilePath -> String -> String -> IO [String]
siblingPages root dir self =
    case resolveStaticPath root (pathSegmentsOf dir) of
        Nothing -> pure []
        Just dirFs -> do
            names <- listDirectory dirFs
            pure [r | n <- names, ".md" `isSuffixOf` n, let r = joinRel dir n, r /= self]

-- | The asset basenames referenced by a page's sidecar @images.yaml@/@attachments.yaml@ (local_path entries).
sidecarAssetNames :: FilePath -> String -> IO [String]
sidecarAssetNames root pageRel =
    case metaDirectoryFor root pageRel of
        Nothing -> pure []
        Just metaFs -> do
            imgs <- readLocalPaths (metaFs ++ "/images.yaml")
            atts <- readLocalPaths (metaFs ++ "/attachments.yaml")
            pure (imgs ++ atts)
  where
    readLocalPaths f = do
        exists <- doesFileExist f
        if exists then fmap (localPathNames . BS.unpack) (BS.readFile f) else pure []

-- | The asset basenames in a sidecar yaml's @local_path:@ values.
localPathNames :: String -> [String]
localPathNames = concatMap nameOf . lines
  where
    nameOf line = case stripPrefix "local_path:" (dropWhile isSpace line) of
        Just rest -> maybeToList (assetBasenameOf (trimValue rest))
        Nothing -> []
    trimValue = dropWhile isSpace

-- | The basename of a same-page @assets/<name>@ reference (handling a @./@ prefix), or 'Nothing'.
assetBasenameOf :: String -> Maybe String
assetBasenameOf value = case dropWhile (== ".") (pathSegmentsOf value) of
    ("assets" : rest@(_ : _)) -> Just (intercalate "/" rest)
    _ -> Nothing

-- | Names whose destination @assets/@ file already holds content differing from the source asset.
assetConflicts :: FilePath -> String -> String -> [String] -> IO [String]
assetConflicts root srcDir destDir names =
    fmap concat $ forM names $ \name ->
        case (assetFs root srcDir name, assetFs root destDir name) of
            (Just sf, Just df) -> do
                srcExists <- doesFileExist sf
                destExists <- doesFileExist df
                if srcExists && destExists
                    then do
                        sb <- BS.readFile sf
                        db <- BS.readFile df
                        pure [name | sb /= db]
                    else pure []
            _ -> pure []

{- | Relocates an exclusive asset (rename) or copies a shared one to the
destination @assets/@; a name already present (identical, as conflicts are refused
beforehand) is reused. Skips an absent source.
-}
relocateOrCopyAsset :: FilePath -> String -> String -> (String, AssetClass) -> IO ()
relocateOrCopyAsset root srcDir destDir (name, cls) =
    case (assetFs root srcDir name, assetFs root destDir name) of
        (Just sf, Just df) -> do
            srcExists <- doesFileExist sf
            when srcExists $ do
                createDirectoryIfMissing True (parentDir df)
                destExists <- doesFileExist df
                if destExists
                    then pure ()
                    else case cls of
                        ExclusiveAsset -> void (renamePath sf df)
                        SharedAsset -> BS.readFile sf >>= BS.writeFile df
        _ -> pure ()
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

-- | The filesystem path of a folder's @assets/<name>@, or 'Nothing' for an unsafe path.
assetFs :: FilePath -> String -> String -> Maybe FilePath
assetFs root dir name = resolveStaticPath root (pathSegmentsOf (joinRel dir ("assets/" ++ name)))

-- | Co-moves a page's sidecar meta directory to follow the moved page (within or across folders).
relocateMeta :: FilePath -> String -> String -> IO ()
relocateMeta root srcRel newRel =
    case (metaDirectoryFor root srcRel, metaDirectoryFor root newRel) of
        (Just srcMeta, Just destMeta) -> do
            srcExists <- doesDirectoryExist srcMeta
            destExists <- doesDirectoryExist destMeta
            -- Never clobber an existing destination meta dir (an orphan edge); only
            -- co-move when the source has one and the destination is free.
            when (srcExists && not destExists) $ do
                createDirectoryIfMissing True (parentDir destMeta)
                void (renamePath srcMeta destMeta)
        _ -> pure ()
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

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
