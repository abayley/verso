{- | In-server section move (RFC-0027, phase 2): relocate a section folder to a new
parent and/or slug, preserving link integrity. The pure cores do the work --
'DocumentLinks.planMoveRewrites' computes the link rewrites across the
whole tree, 'Verso.DocumentListing' relocates the parent @index.md@ listing card
-- and this module supplies the IO: enumerating the tree's pages, the refusals
(root, cycle, collision), the @rename(2)@, and the writes.

Every operation is preview-then-confirm (RFC-0027 safety): with @confirm@ 'False' it
returns the impact ('MovePlan') without writing; with 'True' it applies the move and
returns the same plan marked applied. A move is best-effort transactional: the
rewrites are computed up front against the pre-move tree, then the directory is
renamed and the rewritten pages and listings are written.
-}
module Verso.TreeMove (
    RelevantQuery (..),
    RelevantPages,
    scanRelevant,
    indexRelevant,
    MovePlan (..),
    moveSection,
    movePage,
    movePlanJson,
    DeleteOutcome (..),
    deleteTarget,
    restoreFromTrash,
    ReplayEntry (..),
    replayLog,
    replayReportJson,
    listTrash,
    trashListJson,
) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Static as Static
import qualified System.Directory as Directory
import qualified Verso.DocumentLinks as DocumentLinks
import qualified Verso.DocumentListing as DocumentListing
import qualified Verso.DocumentMeta as DocumentMeta
import qualified Verso.LinkIndex as LinkIndex
import qualified Verso.LinkIndexStore as LinkIndexStore
import qualified Verso.OperationLog as OperationLog
import qualified Verso.Trash as Trash

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

{- | How a move/delete finds the pages it must inspect and rewrite (RFC-0029): the
target's byte @hint@ and an optional @subtree@ prefix for the byte-prefiltered scan,
plus the resolved-path @region@ predicate for the link-index lookup. A backend uses the
fields it needs -- the scan reads @hint@/@subtree@, the index reads @region@ -- so the
same query drives either.
-}
data RelevantQuery = RelevantQuery
    { rqHint :: BS.ByteString
    , rqSubtree :: Maybe String
    , rqRegion :: String -> Bool
    }

{- | A page source: the @(treePath, body)@ pages an operation must process for a query.
'scanRelevant' (the byte-prefiltered whole-tree read) and 'indexRelevant' (the
freshness-checked link index) are the two backends; the server uses the index,
@replay-tool@ and the unit tests use the scan.
-}
type RelevantPages = FilePath -> RelevantQuery -> IO [(String, BS.ByteString)]

-- | The scan backend: the byte-prefiltered whole-tree read (RFC-0027), unchanged. The index's rebuild fallback and @replay-tool@'s mechanism.
scanRelevant :: RelevantPages
scanRelevant root query = enumerateRelevant root (rqHint query) (rqSubtree query)

{- | The index backend (RFC-0029): consult the warm in-memory link index (no
per-operation filesystem walk) for the candidate pages (the region's own pages plus
everything linking into it), then read just those bodies. The pure planners
('DocumentLinks.planMoveRewrites'/'DocumentLinks.referrersMatching') then compute the exact edits/referrers over this
candidate set -- identical to running over the whole tree, since a page outside the
candidate set has no link into the region.
-}
indexRelevant :: LinkIndexStore.LinkIndexStore -> RelevantPages
indexRelevant store root query = do
    index <- LinkIndexStore.currentIndex store
    let paths = LinkIndex.rewriteCandidates (rqRegion query) index
    candidates <- mapM readCandidate paths
    pure (Maybe.catMaybes candidates)
  where
    readCandidate path = fmap (fmap (withPath path)) (readRel root path)
    withPath path body = (path, body)

-- | The subtree-membership predicate for a region path (the path itself and its descendants).
inRegion :: String -> String -> Bool
inRegion prefix path = path == prefix || (prefix ++ "/") `List.isPrefixOf` path

{- | Moves the section at @srcRel@ under @destParentRel@ with slug @slug@ (the
source's own slug when @slug@ is empty), previewing when @confirm@ is 'False' and
applying when 'True'. Returns 'Left' with a reason on refusal (the root, a cycle,
an unsafe path, a missing destination parent, or a destination collision). @findRelevant@
supplies the pages to rewrite ('scanRelevant' or 'indexRelevant').
-}
moveSection :: RelevantPages -> FilePath -> String -> String -> String -> Bool -> IO (Either String MovePlan)
moveSection findRelevant root rawSrcRel rawDestParentRel rawSlug confirm
    | null srcSegs = pure (Left "cannot move the root")
    | otherwise =
        case (Static.resolveStaticPath root srcSegs, Static.resolveStaticPath root newSegs, Static.resolveStaticPath root destParentSegs) of
            (Nothing, _, _) -> pure (Left "unsafe source path")
            (_, Nothing, _) -> pure (Left "unsafe destination slug")
            (_, _, Nothing) -> pure (Left "unsafe destination path")
            (Just srcFs, Just newFs, Just destParentFs)
                | srcRel == newPrefix -> pure (Left "destination is the source")
                | (srcRel ++ "/") `List.isPrefixOf` newPrefix -> pure (Left "cannot move a section into itself")
                | otherwise -> withChecks srcFs newFs destParentFs
  where
    -- Canonicalise the raw request paths (drop empty/doubled/edge slashes) so the
    -- string cycle checks and the listing-match target align with resolved paths.
    srcSegs = DocumentLinks.pathSegmentsOf rawSrcRel
    destParentSegs = DocumentLinks.pathSegmentsOf rawDestParentRel
    srcRel = List.intercalate "/" srcSegs
    destParentRel = List.intercalate "/" destParentSegs
    slug = if null rawSlug then last srcSegs else rawSlug
    newPrefix = joinRel destParentRel slug
    newSegs = DocumentLinks.pathSegmentsOf newPrefix

    withChecks srcFs newFs destParentFs = do
        srcIsDir <- Directory.doesDirectoryExist srcFs
        destParentIsDir <- Directory.doesDirectoryExist destParentFs
        collidesDir <- Directory.doesDirectoryExist newFs
        collidesFile <- Directory.doesFileExist newFs
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
        pages <- findRelevant root (RelevantQuery (BS.pack (last srcSegs)) (Just srcRel) (inRegion srcRel))
        let srcParentRel = parentRel srcRel
            srcIndexRel = indexRel srcParentRel
            destIndexRel = indexRel destParentRel
            excluded = [srcIndexRel, destIndexRel]
            rewritePages = [(p, b) | (p, b) <- pages, p `notElem` excluded]
            rewrites = DocumentLinks.planMoveRewrites (srcRel, newPrefix) rewritePages
            changed = [Maybe.fromMaybe p (DocumentLinks.relocatePath srcRel newPrefix p) | (p, _) <- rewrites]
        if not confirm
            then pure (Right (MovePlan srcRel newPrefix changed False))
            else do
                ok <- FileSystem.renamePath srcFs newFs
                if not ok
                    then pure (Left "rename failed")
                    else do
                        Monad.forM_ rewrites $ \(oldPath, newText) ->
                            writeRel root (Maybe.fromMaybe oldPath (DocumentLinks.relocatePath srcRel newPrefix oldPath)) newText
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
            let (t', r) = DocumentListing.removeListingEntry srcParentRel oldTarget (BS.unpack t)
             in writeRel root srcIndexRel (BS.pack t') >> pure r
        Nothing -> pure Nothing
    let entry = Maybe.fromMaybe synth removed
    destBase <- fmap (maybe "" BS.unpack) (readRel root destIndexRel)
    writeRel root destIndexRel (BS.pack (DocumentListing.addListingEntry destParentRel newTarget entry destBase))
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
        ("- [" ++ title ++ "](./" ++ last (DocumentLinks.pathSegmentsOf newPrefix) ++ "/index.md)")
  where
    newSectionIndexFs = Maybe.fromMaybe "" (Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf (newPrefix ++ "/index.md")))

{- | Moves the page at @srcRel@ (a @.md@ tree path) under @destParentRel@ with slug
@slug@ (the source's own base name when empty), previewing when @confirm@ is 'False'.
A same-folder change is a rename; a cross-folder move additionally co-moves the
sidecar meta directory and runs the asset shared/exclusive analysis (ADR-062),
relocating exclusive assets and copying shared ones. Refuses the root-of-page
edge cases: an unsafe path, a missing source/destination parent, a destination
collision, a no-op (destination is the source), or a destination asset name that
already holds different content. @findRelevant@ supplies the pages to rewrite
('scanRelevant' or 'indexRelevant').
-}
movePage :: RelevantPages -> FilePath -> String -> String -> String -> Bool -> IO (Either String MovePlan)
movePage findRelevant root rawSrcRel rawDestParentRel rawSlug confirm
    | not (".md" `List.isSuffixOf` srcRel) = pure (Left "source is not a page")
    | otherwise =
        case (Static.resolveStaticPath root srcSegs, Static.resolveStaticPath root newSegs, Static.resolveStaticPath root destParentSegs) of
            (Nothing, _, _) -> pure (Left "unsafe source path")
            (_, Nothing, _) -> pure (Left "unsafe destination slug")
            (_, _, Nothing) -> pure (Left "unsafe destination path")
            (Just srcFs, Just newFs, Just destParentFs)
                | srcRel == newPath -> pure (Left "destination is the source")
                | otherwise -> withChecks srcFs newFs destParentFs
  where
    srcSegs = DocumentLinks.pathSegmentsOf rawSrcRel
    srcRel = List.intercalate "/" srcSegs
    destParentSegs = DocumentLinks.pathSegmentsOf rawDestParentRel
    destParentRel = List.intercalate "/" destParentSegs
    base = dropDotMd (last srcSegs)
    slug = if null rawSlug then base else rawSlug
    newPath = joinRel destParentRel (slug ++ ".md")
    newSegs = DocumentLinks.pathSegmentsOf newPath
    srcDir = parentRel srcRel

    withChecks srcFs newFs destParentFs = do
        srcIsFile <- Directory.doesFileExist srcFs
        destParentIsDir <- Directory.doesDirectoryExist destParentFs
        collides <- Directory.doesFileExist newFs
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
            then pure (Left ("destination asset already exists with different content: " ++ List.intercalate ", " conflicts))
            else do
                pages <- findRelevant root (RelevantQuery (BS.pack (last (DocumentLinks.pathSegmentsOf srcRel))) (Just srcRel) (== srcRel))
                let rewritePages = filter ((`notElem` excluded) . fst) pages
                    rewrites = DocumentLinks.planPageMove (srcRel, newPath) rewritePages
                    changed = map fst rewrites
                if not confirm
                    then pure (Right (MovePlan srcRel newPath changed False))
                    else do
                        -- Rename the .md first: it is the cheapest op and the only one
                        -- whose failure has no clean recovery, so on failure nothing
                        -- destructive has happened yet (the assets/meta still co-move
                        -- from their unchanged source locations afterwards).
                        ok <- FileSystem.renamePath srcFs newFs
                        if not ok
                            then pure (Left "rename failed")
                            else do
                                Monad.forM_ assets (relocateOrCopyAsset root srcDir destParentRel)
                                relocateMeta root srcRel newPath
                                Monad.forM_ rewrites (uncurry (writeRel root))
                                title <- frontmatterNameOf newFs
                                relocateEntry root srcDir destParentRel srcRel newPath ("- [" ++ title ++ "](./" ++ slug ++ ".md)")
                                pure (Right (MovePlan srcRel newPath changed True))

-- | Drops a trailing @.md@ from a filename.
dropDotMd :: String -> String
dropDotMd name
    | ".md" `List.isSuffixOf` name = take (length name - length ".md") name
    | otherwise = name

-- | The shared/exclusive classification of the moving page's assets against its source-folder peers (ADR-062).
classifyMovingAssets :: FilePath -> String -> String -> IO [(String, DocumentLinks.AssetClass)]
classifyMovingAssets root srcRel srcDir = do
    movingBody <- fmap (Maybe.fromMaybe BS.empty) (readRel root srcRel)
    movingSidecar <- sidecarAssetNames root srcRel
    let movingAssets = List.nub (DocumentLinks.assetNamesIn movingBody ++ movingSidecar)
    peers <- siblingPages root srcDir srcRel
    peerRefs <- Monad.forM peers $ \peer -> do
        body <- fmap (Maybe.fromMaybe BS.empty) (readRel root peer)
        sidecar <- sidecarAssetNames root peer
        pure (List.nub (DocumentLinks.assetNamesIn body ++ sidecar))
    pure (DocumentLinks.classifyAssets movingAssets peerRefs)

-- | The @.md@ pages directly in a folder (non-recursive), excluding the named page.
siblingPages :: FilePath -> String -> String -> IO [String]
siblingPages root dir self =
    case Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf dir) of
        Nothing -> pure []
        Just dirFs -> do
            names <- Directory.listDirectory dirFs
            pure [r | n <- names, ".md" `List.isSuffixOf` n, let r = joinRel dir n, r /= self]

-- | The asset basenames referenced by a page's sidecar @images.yaml@/@attachments.yaml@ (local_path entries).
sidecarAssetNames :: FilePath -> String -> IO [String]
sidecarAssetNames root pageRel =
    case DocumentMeta.metaDirectoryFor root pageRel of
        Nothing -> pure []
        Just metaFs -> do
            imgs <- readLocalPaths (metaFs ++ "/images.yaml")
            atts <- readLocalPaths (metaFs ++ "/attachments.yaml")
            pure (imgs ++ atts)
  where
    readLocalPaths f = do
        exists <- Directory.doesFileExist f
        if exists then fmap (localPathNames . BS.unpack) (BS.readFile f) else pure []

-- | The asset basenames in a sidecar yaml's @local_path:@ values.
localPathNames :: String -> [String]
localPathNames = concatMap nameOf . lines
  where
    nameOf line = case List.stripPrefix "local_path:" (dropWhile Char.isSpace line) of
        Just rest -> Maybe.maybeToList (assetBasenameOf (trimValue rest))
        Nothing -> []
    trimValue = dropWhile Char.isSpace

-- | The basename of a same-page @assets/<name>@ reference (handling a @./@ prefix), or 'Nothing'.
assetBasenameOf :: String -> Maybe String
assetBasenameOf value = case dropWhile (== ".") (DocumentLinks.pathSegmentsOf value) of
    ("assets" : rest@(_ : _)) -> Just (List.intercalate "/" rest)
    _ -> Nothing

-- | Names whose destination @assets/@ file already holds content differing from the source asset.
assetConflicts :: FilePath -> String -> String -> [String] -> IO [String]
assetConflicts root srcDir destDir names =
    fmap concat $ Monad.forM names $ \name ->
        case (assetFs root srcDir name, assetFs root destDir name) of
            (Just sf, Just df) -> do
                srcExists <- Directory.doesFileExist sf
                destExists <- Directory.doesFileExist df
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
relocateOrCopyAsset :: FilePath -> String -> String -> (String, DocumentLinks.AssetClass) -> IO ()
relocateOrCopyAsset root srcDir destDir (name, cls) =
    case (assetFs root srcDir name, assetFs root destDir name) of
        (Just sf, Just df) -> do
            srcExists <- Directory.doesFileExist sf
            Monad.when srcExists $ do
                Directory.createDirectoryIfMissing True (parentDir df)
                destExists <- Directory.doesFileExist df
                if destExists
                    then pure ()
                    else case cls of
                        DocumentLinks.ExclusiveAsset -> Monad.void (FileSystem.renamePath sf df)
                        DocumentLinks.SharedAsset -> BS.readFile sf >>= BS.writeFile df
        _ -> pure ()
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

-- | The filesystem path of a folder's @assets/<name>@, or 'Nothing' for an unsafe path.
assetFs :: FilePath -> String -> String -> Maybe FilePath
assetFs root dir name = Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf (joinRel dir ("assets/" ++ name)))

-- | Co-moves a page's sidecar meta directory to follow the moved page (within or across folders).
relocateMeta :: FilePath -> String -> String -> IO ()
relocateMeta root srcRel newRel =
    case (DocumentMeta.metaDirectoryFor root srcRel, DocumentMeta.metaDirectoryFor root newRel) of
        (Just srcMeta, Just destMeta) -> do
            srcExists <- Directory.doesDirectoryExist srcMeta
            destExists <- Directory.doesDirectoryExist destMeta
            -- Never clobber an existing destination meta dir (an orphan edge); only
            -- co-move when the source has one and the destination is free.
            Monad.when (srcExists && not destExists) $ do
                Directory.createDirectoryIfMissing True (parentDir destMeta)
                Monad.void (FileSystem.renamePath srcMeta destMeta)
        _ -> pure ()
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

-- | The outcome of a delete: the target was moved to trash, or refused because other pages still link in.
data DeleteOutcome
    = Deleted {delTrashId :: String, delPath :: String, delKind :: String}
    | Refused {refReferrers :: [(String, String)]}
    deriving (Eq, Show)

{- | Deletes the page or section at @relPath@ (RFC-0027 phase 4 + RFC-0028 trash).
The target's parent index.md listing entry is not counted as a referrer (it is
removed as part of the delete); if any /other/ page still links to the target (for a
section, any page outside the subtree links into it) the delete is 'Refused' with the
referrer list and nothing is written (ADR-063). Otherwise the target -- a page's
@.md@, sidecar meta dir, and exclusive assets, or a whole section folder -- is moved
into the trash entry @trashId@ with a provenance manifest (ADR-065), the listing
entry removed, and 'Deleted' returned for the caller to log. @findRelevant@ supplies the
pages scanned for referrers ('scanRelevant' or 'indexRelevant').
-}
deleteTarget :: RelevantPages -> FilePath -> FilePath -> String -> String -> Int -> IO (Either String DeleteOutcome)
deleteTarget findRelevant root trashRoot relPathRaw trashId seqNo
    | null segs = pure (Left "cannot delete the root")
    | otherwise = case Static.resolveStaticPath root segs of
        Nothing -> pure (Left "unsafe path")
        Just fs -> do
            exists <- if isPage then Directory.doesFileExist fs else Directory.doesDirectoryExist fs
            if not exists
                then pure (Left "not found")
                else do
                    -- The referrer scan needs the region's pages (to exclude subtree-internal
                    -- links) and everything linking into it. The index returns exactly that
                    -- candidate set; the scan byte-prefilters on the target's name (only files
                    -- whose raw bytes mention it can link to it) -- either way far less than the
                    -- whole corpus, the difference between sub-second and ~90s on a large tree.
                    let region = if isPage then (== relPath) else inRegion relPath
                    pages <- findRelevant root (RelevantQuery (BS.pack (last segs)) Nothing region)
                    if isPage
                        then
                            let referrers = DocumentLinks.referrersMatching (== relPath) [parentIndexRel, relPath] pages
                             in if not (null referrers)
                                    then pure (Right (Refused referrers))
                                    else applyPageDelete root trashRoot relPath parent parentIndexRel trashId seqNo
                        else
                            let inSub t = t == relPath || ((relPath ++ "/") `List.isPrefixOf` t)
                                subtreePaths = [p | (p, _) <- pages, inSub p]
                                referrers = DocumentLinks.referrersMatching inSub (parentIndexRel : subtreePaths) pages
                             in if not (null referrers)
                                    then pure (Right (Refused referrers))
                                    else applySectionDelete root trashRoot relPath parent parentIndexRel trashId seqNo
  where
    segs = DocumentLinks.pathSegmentsOf relPathRaw
    relPath = List.intercalate "/" segs
    isPage = ".md" `List.isSuffixOf` relPath
    parent = parentRel relPath
    parentIndexRel = indexRel parent

-- | Moves a page (its .md, sidecar meta dir, exclusive assets) to trash, removes its listing bullet, writes the manifest.
applyPageDelete :: FilePath -> FilePath -> String -> String -> String -> String -> Int -> IO (Either String DeleteOutcome)
applyPageDelete root trashRoot relPath parent parentIndexRel trashId seqNo = do
    let entryDir = trashRoot ++ "/" ++ trashId
        base = last (DocumentLinks.pathSegmentsOf relPath)
        metaRel = joinRel parent ("meta/" ++ dropDotMd base ++ ".meta")
    Directory.createDirectoryIfMissing True entryDir
    assetClasses <- classifyMovingAssets root relPath parent
    let exclusives = [name | (name, DocumentLinks.ExclusiveAsset) <- assetClasses]
    mdItem <- moveIntoTrash root entryDir "page.md" relPath False
    metaItem <- moveDirIntoTrash root entryDir "meta" metaRel
    assetItems <-
        Monad.zipWithM
            (\i name -> moveIntoTrash root entryDir ("asset-" ++ show i) (joinRel parent ("assets/" ++ name)) False)
            [(0 :: Int) ..]
            exclusives
    removed <- removeParentListing root parentIndexRel parent relPath
    let items = Maybe.catMaybes (mdItem : metaItem : assetItems)
    writeManifest entryDir (Trash.Manifest relPath "page" seqNo removed items)
    pure (Right (Deleted trashId relPath "page"))

-- | Moves a whole section folder to trash, removes its listing card, writes the manifest.
applySectionDelete :: FilePath -> FilePath -> String -> String -> String -> String -> Int -> IO (Either String DeleteOutcome)
applySectionDelete root trashRoot relPath parent parentIndexRel trashId seqNo = do
    let entryDir = trashRoot ++ "/" ++ trashId
    Directory.createDirectoryIfMissing True entryDir
    removed <- removeParentListing root parentIndexRel parent (relPath ++ "/index.md")
    payloadItem <- moveIntoTrash root entryDir "payload" relPath True
    writeManifest entryDir (Trash.Manifest relPath "section" seqNo removed (Maybe.catMaybes [payloadItem]))
    pure (Right (Deleted trashId relPath "section"))

{- | Restores a trash entry to its provenance path (RFC-0028), re-adding the parent
listing entry. Refuses if the original location is now occupied (prompting a new
location, like a move collision). Returns the restored @(path, kind)@ for the caller
to log a @restore@ operation.
-}
restoreFromTrash :: FilePath -> FilePath -> String -> IO (Either String (String, String))
restoreFromTrash root trashRoot trashId = do
    let entryDir = trashRoot ++ "/" ++ trashId
        manifestFile = entryDir ++ "/manifest"
    hasManifest <- Directory.doesFileExist manifestFile
    if not hasManifest
        then pure (Left "trash entry not found")
        else do
            text <- fmap BS.unpack (BS.readFile manifestFile)
            case Trash.parseManifest text of
                Nothing -> pure (Left "corrupt trash manifest")
                Just manifest -> do
                    occupied <- targetOccupied root (Trash.manPath manifest) (Trash.manKind manifest)
                    if occupied
                        then pure (Left "original location is occupied")
                        else do
                            Monad.forM_ (Trash.manItems manifest) (restoreItem root entryDir)
                            reAddListing root manifest
                            Monad.void (FileSystem.removeFilePath manifestFile)
                            Monad.void (FileSystem.removeEmptyDir entryDir)
                            pure (Right (Trash.manPath manifest, Trash.manKind manifest))

-- | Moves one tree path into a trash entry under the given stored name (best-effort), yielding its manifest item.
moveIntoTrash :: FilePath -> FilePath -> String -> String -> Bool -> IO (Maybe Trash.TrashItem)
moveIntoTrash root entryDir stored originRel isDir =
    case Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf originRel) of
        Nothing -> pure Nothing
        Just srcFs -> do
            ok <- FileSystem.renamePath srcFs (entryDir ++ "/" ++ stored)
            pure (if ok then Just (Trash.TrashItem stored isDir originRel) else Nothing)

-- | As 'moveIntoTrash' for a directory that may be absent (a page with no sidecar meta dir).
moveDirIntoTrash :: FilePath -> FilePath -> String -> String -> IO (Maybe Trash.TrashItem)
moveDirIntoTrash root entryDir stored originRel =
    case Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf originRel) of
        Nothing -> pure Nothing
        Just srcFs -> do
            exists <- Directory.doesDirectoryExist srcFs
            if not exists then pure Nothing else moveIntoTrash root entryDir stored originRel True

-- | Moves one trashed item back to its origin tree path (creating parent directories).
restoreItem :: FilePath -> FilePath -> Trash.TrashItem -> IO ()
restoreItem root entryDir item =
    case Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf (Trash.itemOrigin item)) of
        Nothing -> pure ()
        Just destFs -> do
            Directory.createDirectoryIfMissing True (parentDir destFs)
            Monad.void (FileSystem.renamePath (entryDir ++ "/" ++ Trash.itemStored item) destFs)
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

-- | Removes a target's entry from its parent index.md listing, returning the removed line.
removeParentListing :: FilePath -> String -> String -> String -> IO (Maybe String)
removeParentListing root parentIndexRel parent target = do
    txt <- readRel root parentIndexRel
    case txt of
        Just t ->
            let (t', removed) = DocumentListing.removeListingEntry parent target (BS.unpack t)
             in writeRel root parentIndexRel (BS.pack t') >> pure removed
        Nothing -> pure Nothing

-- | Re-adds a restored item's listing entry to its parent index.md (the preserved line, or nothing when absent).
reAddListing :: FilePath -> Trash.Manifest -> IO ()
reAddListing root manifest =
    case Trash.manListing manifest of
        Nothing -> pure ()
        Just entry -> do
            base <- fmap (maybe "" BS.unpack) (readRel root parentIndexRel)
            writeRel root parentIndexRel (BS.pack (DocumentListing.addListingEntry parent target entry base))
  where
    parent = parentRel (Trash.manPath manifest)
    parentIndexRel = indexRel parent
    target = if Trash.manKind manifest == "section" then Trash.manPath manifest ++ "/index.md" else Trash.manPath manifest

-- | Whether a tree path is currently occupied (a page's file, a section's directory).
targetOccupied :: FilePath -> String -> String -> IO Bool
targetOccupied root path kind =
    case Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf path) of
        Nothing -> pure True
        Just fs -> if kind == "section" then Directory.doesDirectoryExist fs else Directory.doesFileExist fs

-- | Writes a trash entry's provenance manifest.
writeManifest :: FilePath -> Trash.Manifest -> IO ()
writeManifest entryDir manifest = BS.writeFile (entryDir ++ "/manifest") (BS.pack (Trash.renderManifest manifest))

{- | Lists the trash entries (RFC-0028) as @(id, originalPath, kind)@, newest-id last,
reading each entry's manifest. Entries without a readable manifest are skipped.
-}
listTrash :: FilePath -> IO [(String, String, String)]
listTrash trashRoot = do
    exists <- Directory.doesDirectoryExist trashRoot
    if not exists
        then pure []
        else do
            ids <- Directory.listDirectory trashRoot
            entries <- mapM entryFor ids
            pure (Maybe.catMaybes entries)
  where
    entryFor entryId = do
        let manifestFile = trashRoot ++ "/" ++ entryId ++ "/manifest"
        hasManifest <- Directory.doesFileExist manifestFile
        if not hasManifest
            then pure Nothing
            else do
                text <- fmap BS.unpack (BS.readFile manifestFile)
                pure (fmap (\m -> (entryId, Trash.manPath m, Trash.manKind m)) (Trash.parseManifest text))

-- | The trash listing as JSON @[{"id","path","kind"}]@.
trashListJson :: [(String, String, String)] -> String
trashListJson entries =
    "[" ++ List.intercalate "," (map one entries) ++ "]"
  where
    one (entryId, path, kind) =
        "{\"id\":" ++ jsonStr entryId ++ ",\"path\":" ++ jsonStr path ++ ",\"kind\":" ++ jsonStr kind ++ "}"

-- | One operation's outcome during replay: its seq, type, and @applied@ or @skipped: <reason>@ status.
data ReplayEntry = ReplayEntry
    { reSeq :: Int
    , reType :: String
    , reStatus :: String
    }
    deriving (Eq, Show)

{- | Replays the operation log onto a (refreshed, original-layout) corpus in @seq@
order (RFC-0028 phase 4), each operation going through the same move/delete/restore
machinery. Best-effort: an operation whose precondition no longer holds (source
missing, destination occupied, now-referenced) is skipped and recorded, and replay
continues. A delete reuses the operation's recorded trash id so a later restore in
the log finds the entry; replay does not append to the log.
-}
replayLog :: FilePath -> FilePath -> [OperationLog.Operation] -> IO [ReplayEntry]
replayLog root trashRoot = mapM replayOne
  where
    replayOne op = do
        status <- applyReplayOp root trashRoot op
        pure (ReplayEntry (OperationLog.opSeq op) (typeWord (OperationLog.opType op)) status)

-- | Applies one operation during replay, returning @applied@ or @skipped: <reason>@.
applyReplayOp :: FilePath -> FilePath -> OperationLog.Operation -> IO String
applyReplayOp root trashRoot op = case OperationLog.opType op of
    OperationLog.OpMove -> do
        let from = Maybe.fromMaybe "" (OperationLog.opFrom op)
            to = Maybe.fromMaybe "" (OperationLog.opTo op)
            move = if OperationLog.opKind op == "page" then movePage else moveSection
        -- replay-tool is a separate process with no warm index, so it uses the scan (ADR-066).
        result <- move scanRelevant root from (parentRel to) (slugOfPath (OperationLog.opKind op) to) True
        pure (movePlanStatus result)
    OperationLog.OpDelete -> do
        let from = Maybe.fromMaybe "" (OperationLog.opFrom op)
            trashId = Maybe.fromMaybe (show (OperationLog.opSeq op)) (OperationLog.opTrash op)
        result <- deleteTarget scanRelevant root trashRoot from trashId (OperationLog.opSeq op)
        pure $ case result of
            Left err -> "skipped: " ++ err
            Right (Refused _) -> "skipped: referenced"
            Right Deleted{} -> "applied"
    OperationLog.OpRestore -> do
        result <- restoreFromTrash root trashRoot (Maybe.fromMaybe "" (OperationLog.opTrash op))
        pure (either ("skipped: " ++) (const "applied") result)

-- | The status word for a move result during replay.
movePlanStatus :: Either String MovePlan -> String
movePlanStatus (Left err) = "skipped: " ++ err
movePlanStatus (Right plan) = if planApplied plan then "applied" else "skipped: not applied"

-- | The destination slug to move a path to: a page's basename without @.md@, a section's last segment.
slugOfPath :: String -> String -> String
slugOfPath kind path = case DocumentLinks.pathSegmentsOf path of
    [] -> ""
    segs -> if kind == "page" then dropDotMd (last segs) else last segs

-- | The wire word for an operation type.
typeWord :: OperationLog.OpType -> String
typeWord OperationLog.OpMove = "move"
typeWord OperationLog.OpDelete = "delete"
typeWord OperationLog.OpRestore = "restore"

-- | A replay report as JSON @{"replayed":[{"seq","type","status"}]}@.
replayReportJson :: [ReplayEntry] -> String
replayReportJson entries =
    "{\"replayed\":[" ++ List.intercalate "," (map one entries) ++ "]}"
  where
    one e =
        "{\"seq\":"
            ++ show (reSeq e)
            ++ ",\"type\":"
            ++ jsonStr (reType e)
            ++ ",\"status\":"
            ++ jsonStr (reStatus e)
            ++ "}"

{- | Reads the @.md@ pages /relevant/ to an operation, as @(treeRelPath, body)@, skipping
dot-entries and @assets@/@meta@ folders. A page is returned only when its raw bytes contain
@hint@ -- the target's name, which any relative link to it must contain -- or when it lies within
@subtreePrefix@ (the moved subtree, whose own pages must be rewritten even when they do not mention
the hint). Files matching neither are skipped __without unpacking or link-parsing__, which is the
difference between a sub-second and a ~90-second scan on a large corpus (no index, ADR-059). The
byte pre-filter never drops a real referrer (false positives only cost a parse), since a relative
link's path always contains the slug/filename of what it points at.
-}
enumerateRelevant :: FilePath -> BS.ByteString -> Maybe String -> IO [(String, BS.ByteString)]
enumerateRelevant root hint subtreePrefix = walk ""
  where
    inSubtree path = case subtreePrefix of
        Nothing -> False
        Just prefix -> path == prefix || (prefix ++ "/") `List.isPrefixOf` path
    walk rel = do
        let dirFs = Maybe.fromMaybe root (Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf rel))
        names <- Directory.listDirectory dirFs
        fmap concat (mapM (collect rel dirFs) names)
    collect rel dirFs name
        | isDot name = pure []
        | otherwise = do
            let childRel = joinRel rel name
                childFs = dirFs ++ "/" ++ name
            isDir <- Directory.doesDirectoryExist childFs
            if isDir
                then if name == "assets" || name == "meta" then pure [] else walk childRel
                else
                    if ".md" `List.isSuffixOf` name
                        then do
                            bytes <- BS.readFile childFs
                            pure [(childRel, bytes) | BS.isInfixOf hint bytes || inSubtree childRel]
                        else pure []
    isDot ('.' : _) = True
    isDot _ = False

-- | Reads a tree-relative file as bytes, or 'Nothing' when it is absent or its path is unsafe.
readRel :: FilePath -> String -> IO (Maybe BS.ByteString)
readRel root rel =
    case Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf rel) of
        Nothing -> pure Nothing
        Just fs -> do
            exists <- Directory.doesFileExist fs
            if exists then fmap Just (BS.readFile fs) else pure Nothing

-- | Writes a tree-relative file's bytes (creating parent directories), ignoring an unsafe path.
writeRel :: FilePath -> String -> BS.ByteString -> IO ()
writeRel root rel content =
    case Static.resolveStaticPath root (DocumentLinks.pathSegmentsOf rel) of
        Nothing -> pure ()
        Just fs -> do
            Directory.createDirectoryIfMissing True (parentDir fs)
            BS.writeFile fs content
  where
    parentDir = reverse . drop 1 . dropWhile (/= '/') . reverse

-- | The frontmatter @name@ of an index.md (for a synthesised listing entry), or a fallback.
frontmatterNameOf :: FilePath -> IO String
frontmatterNameOf fs = do
    exists <- Directory.doesFileExist fs
    if not exists
        then pure "Untitled"
        else fmap (Maybe.fromMaybe "Untitled" . frontmatterName . BS.unpack) (BS.readFile fs)

-- | Extracts the @name:@ scalar from a leading @---@ frontmatter block.
frontmatterName :: String -> Maybe String
frontmatterName text = case lines text of
    ("---" : rest) -> lookupName (takeWhile (/= "---") rest)
    _ -> Nothing
  where
    lookupName [] = Nothing
    lookupName (l : ls)
        | "name:" `List.isPrefixOf` l = Just (unquote (trim (drop (length "name:") l)))
        | otherwise = lookupName ls
    trim = dropWhile (== ' ')
    unquote s
        | length s >= 2 && head s == '"' && last s == '"' = init (drop 1 s)
        | otherwise = s

-- | The parent tree path of a tree path (its segments minus the last; @""@ at the root).
parentRel :: String -> String
parentRel rel = List.intercalate "/" (initOrEmpty (DocumentLinks.pathSegmentsOf rel))
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
        ++ List.intercalate "," (map jsonStr (planChanged plan))
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
