{-# LANGUAGE TupleSections #-}

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

Every tree path an operation takes is a validated 'TreePath.TreePath' and every
trash entry a 'TreePath.TrashId' (RFC-0044), so the operations are total on
paths: the handler parses once and answers for an unsafe one. The tree layout
(parent, slug, section index, meta directory, peer assets, trash entry) is
'Verso.TreePath'; the pure planners in 'Verso.DocumentLinks' and
'Verso.DocumentListing' work on rendered paths, so this module renders at that seam.
-}
module Verso.TreeMove (
    RelevantQuery (..),
    RelevantPages,
    scanRelevant,
    indexRelevant,
    MovePlan (..),
    moveSection,
    movePage,
    moveTarget,
    slugOf,
    movePlanJson,
    DeleteOutcome (..),
    deleteTarget,
    restoreFromTrash,
    ReplayEntry (..),
    replayLog,
) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Stream as Stream
import qualified MicroHttp.Utf8 as Utf8
import qualified System.Directory as Directory
import qualified Verso.DocumentLinks as DocumentLinks
import qualified Verso.DocumentListing as DocumentListing
import qualified Verso.DocumentMeta as DocumentMeta
import qualified Verso.Frontmatter as Frontmatter
import qualified Verso.Json as Json
import qualified Verso.LinkIndex as LinkIndex
import qualified Verso.LinkIndexStore as LinkIndexStore
import qualified Verso.LinkRewrite as LinkRewrite
import qualified Verso.OperationLog as OperationLog
import qualified Verso.Trash as Trash
import qualified Verso.TreePath as TreePath

{- | The impact of a move: the source and destination tree paths, the tree paths
(final locations, rendered) of the pages whose links change, and whether it was
applied (or is a preview).
-}
data MovePlan = MovePlan
    { planFrom :: TreePath.TreePath
    , planTo :: TreePath.TreePath
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

{- | A page source: the @(treePath, links)@ pages an operation must process for a
query, each page reduced to its links so no body is held (RFC-0039). 'scanRelevant'
(the byte-prefiltered whole-tree read) and 'indexRelevant' (the freshness-checked link
index) are the two backends; the server uses the index, @replay-tool@ and the unit
tests use the scan.
-}
type RelevantPages = FilePath -> RelevantQuery -> IO [(String, [DocumentLinks.Link])]

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
    readCandidate path = case TreePath.parse path of
        Nothing -> pure Nothing
        Just page -> fmap (fmap (withPath path)) (linksRel root page)
    withPath path links = (path, links)

-- | The subtree-membership predicate for a region path (the path itself and its descendants).
inRegion :: String -> String -> Bool
inRegion prefix path = path == prefix || (prefix ++ "/") `List.isPrefixOf` path

{- | Moves the section at @src@ under @destParent@ with slug @slug@ (the source's
own slug when @slug@ is empty), previewing when @confirm@ is 'False' and applying
when 'True'. Returns 'Left' with a reason on refusal (the root, a cycle, an unsafe
slug, a missing destination parent, or a destination collision). @findRelevant@
supplies the pages to rewrite ('scanRelevant' or 'indexRelevant').
-}
moveSection :: RelevantPages -> FilePath -> TreePath.TreePath -> TreePath.TreePath -> String -> Bool -> IO (Either String MovePlan)
moveSection findRelevant root src destParent rawSlug confirm
    | TreePath.isRoot src = pure (Left "cannot move the root")
    | otherwise = case TreePath.child destParent slug of
        Nothing -> pure (Left "unsafe destination slug")
        Just new
            | new == src -> pure (Left "destination is the source")
            | new `TreePath.within` src -> pure (Left "cannot move a section into itself")
            | otherwise -> withChecks new
  where
    slug = if null rawSlug then TreePath.name src else rawSlug
    srcRel = TreePath.render src
    srcFs = TreePath.resolve root src

    withChecks new = do
        let newFs = TreePath.resolve root new
        srcIsDir <- Directory.doesDirectoryExist srcFs
        destParentIsDir <- Directory.doesDirectoryExist (TreePath.resolve root destParent)
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
                            else runMove new newFs

    runMove new newFs = do
        let newPrefix = TreePath.render new
        pages <- findRelevant root (RelevantQuery (BS.pack (TreePath.name src)) (Just srcRel) (inRegion srcRel))
        let srcParent = TreePath.parent src
            excluded = map (TreePath.render . TreePath.sectionIndex) [srcParent, destParent]
            rewritePages = [(p, ls) | (p, ls) <- pages, p `notElem` excluded]
            rewrites = DocumentLinks.planMoveRewrites (srcRel, newPrefix) rewritePages
            relocated p = Maybe.fromMaybe p (DocumentLinks.relocatePath srcRel newPrefix p)
            changed = map (relocated . fst) rewrites
        if not confirm
            then pure (Right (MovePlan src new changed False))
            else do
                outcome <- FileSystem.renamePath srcFs newFs
                case outcome of
                    Left e -> pure (Left ("rename failed (" ++ show e ++ ")"))
                    Right () -> do
                        -- Each page is rewritten at its post-rename location, streaming (RFC-0039).
                        failures <- rewriteEach [(relocated oldPath, DocumentLinks.moveLinkEdit (srcRel, newPrefix) oldPath) | (oldPath, _) <- rewrites]
                        relocateListing root src srcParent destParent new
                        pure (if null failures then Right (MovePlan src new changed True) else Left (unlines failures))
    rewriteEach = fmap Maybe.catMaybes . mapM (uncurry (rewriteRel root))

{- | Relocates a member's listing entry from the source parent's index.md to the
destination parent's, repointing its link from @oldTarget@ to @newTarget@. When the
source had no entry, the synthesised fallback is used. Shared by section move (a grid
card, @newTarget@ ending @/index.md@) and page move (a flat bullet).
-}
relocateEntry :: FilePath -> TreePath.TreePath -> TreePath.TreePath -> String -> String -> String -> IO ()
relocateEntry root srcParent destParent oldTarget newTarget synth = do
    srcText <- readRel root srcIndex
    removed <- case srcText of
        Just t -> do
            (t', r) <- DocumentListing.removeListingEntry (TreePath.render srcParent) oldTarget (Utf8.decodeBytes t)
            writeRel root srcIndex (Utf8.encodeText t')
            pure r
        Nothing -> pure Nothing
    let entry = Maybe.fromMaybe synth removed
    destBase <- fmap (maybe "" Utf8.decodeBytes) (readRel root destIndex)
    added <- DocumentListing.addListingEntry (TreePath.render destParent) newTarget entry destBase
    writeRel root destIndex (Utf8.encodeText added)
  where
    srcIndex = TreePath.sectionIndex srcParent
    destIndex = TreePath.sectionIndex destParent

-- | Relocates the moved section's listing card (a grid card linking the section's index.md).
relocateListing :: FilePath -> TreePath.TreePath -> TreePath.TreePath -> TreePath.TreePath -> TreePath.TreePath -> IO ()
relocateListing root src srcParent destParent new = do
    title <- frontmatterNameOf (TreePath.resolve root (TreePath.sectionIndex new))
    relocateEntry
        root
        srcParent
        destParent
        (TreePath.render (TreePath.sectionIndex src))
        (TreePath.render (TreePath.sectionIndex new))
        ("- [" ++ title ++ "](./" ++ TreePath.name new ++ "/index.md)")

{- | Moves the page at @src@ (a @.md@ tree path) under @destParent@ with slug
@slug@ (the source's own base name when empty), previewing when @confirm@ is 'False'.
A same-folder change is a rename; a cross-folder move additionally co-moves the
sidecar meta directory and runs the asset shared/exclusive analysis (ADR-0062),
relocating exclusive assets and copying shared ones. Refuses the root-of-page
edge cases: an unsafe slug, a missing source/destination parent, a destination
collision, a no-op (destination is the source), or a destination asset name that
already holds different content. @findRelevant@ supplies the pages to rewrite
('scanRelevant' or 'indexRelevant').
-}
movePage :: RelevantPages -> FilePath -> TreePath.TreePath -> TreePath.TreePath -> String -> Bool -> IO (Either String MovePlan)
movePage findRelevant root src destParent rawSlug confirm
    | TreePath.kind src /= TreePath.Page = pure (Left "source is not a page")
    | otherwise = case TreePath.child destParent (slug ++ ".md") of
        Nothing -> pure (Left "unsafe destination slug")
        Just new
            | new == src -> pure (Left "destination is the source")
            | otherwise -> withChecks new
  where
    slug = if null rawSlug then TreePath.slug src else rawSlug
    srcRel = TreePath.render src
    srcFs = TreePath.resolve root src
    srcDir = TreePath.parent src

    withChecks new = do
        let newFs = TreePath.resolve root new
        srcIsFile <- Directory.doesFileExist srcFs
        destParentIsDir <- Directory.doesDirectoryExist (TreePath.resolve root destParent)
        collides <- Directory.doesFileExist newFs
        if not srcIsFile
            then pure (Left "source page not found")
            else
                if not destParentIsDir
                    then pure (Left "destination parent not found")
                    else
                        if collides
                            then pure (Left "destination already exists")
                            else runPageMove new newFs

    runPageMove new newFs = do
        let newPath = TreePath.render new
            crossFolder = srcDir /= destParent
            excluded = map (TreePath.render . TreePath.sectionIndex) [srcDir, destParent]
            srcAssets = TreePath.peerAssets src
            destAssets = TreePath.peerAssets new
        assets <- if crossFolder then classifyMovingAssets root src else pure []
        conflicts <- assetConflicts root srcAssets destAssets (map fst assets)
        if not (null conflicts)
            then pure (Left ("destination asset already exists with different content: " ++ List.intercalate ", " conflicts))
            else do
                pages <- findRelevant root (RelevantQuery (BS.pack (TreePath.name src)) (Just srcRel) (== srcRel))
                let rewritePages = filter ((`notElem` excluded) . fst) pages
                    rewrites = DocumentLinks.planPageMove (srcRel, newPath) rewritePages
                    changed = map fst rewrites
                    decisionFor p
                        | p == newPath = DocumentLinks.pageMoveLinkEdit (srcRel, newPath)
                        | otherwise = DocumentLinks.moveLinkEdit (srcRel, newPath) p
                if not confirm
                    then pure (Right (MovePlan src new changed False))
                    else do
                        -- Rename the .md first: it is the cheapest op and the only one
                        -- whose failure has no clean recovery, so on failure nothing
                        -- destructive has happened yet (the assets/meta still co-move
                        -- from their unchanged source locations afterwards).
                        outcome <- FileSystem.renamePath srcFs newFs
                        case outcome of
                            Left e -> pure (Left ("rename failed (" ++ show e ++ ")"))
                            Right () -> do
                                Monad.forM_ assets (relocateOrCopyAsset root srcAssets destAssets)
                                relocateMeta root src new
                                failures <- fmap Maybe.catMaybes (mapM (\(p, _) -> rewriteRel root p (decisionFor p)) rewrites)
                                title <- frontmatterNameOf newFs
                                relocateEntry root srcDir destParent srcRel newPath ("- [" ++ title ++ "](./" ++ slug ++ ".md)")
                                pure (if null failures then Right (MovePlan src new changed True) else Left (unlines failures))

{- | 'movePage' or 'moveSection' by the kind the caller knows the target to be
(the request path's suffix, or an operation log record's kind word). The one
place that dispatch is written.
-}
moveTarget :: TreePath.Kind -> RelevantPages -> FilePath -> TreePath.TreePath -> TreePath.TreePath -> String -> Bool -> IO (Either String MovePlan)
moveTarget TreePath.Page = movePage
moveTarget TreePath.Section = moveSection

{- | The slug a path moves back to, by the kind its record gives it: a page's name
without @.md@, a section's whole name (a section may be named like a page).
-}
slugOf :: TreePath.Kind -> TreePath.TreePath -> String
slugOf TreePath.Page = TreePath.slug
slugOf TreePath.Section = TreePath.name

-- | The shared/exclusive classification of the moving page's assets against its source-folder peers (ADR-0062).
classifyMovingAssets :: FilePath -> TreePath.TreePath -> IO [(String, DocumentLinks.AssetClass)]
classifyMovingAssets root src = do
    movingLinks <- fmap (Maybe.fromMaybe []) (linksRel root src)
    movingSidecar <- sidecarAssetNames root src
    let movingAssets = List.nub (DocumentLinks.assetNamesIn movingLinks ++ movingSidecar)
    peers <- siblingPages root src
    peerRefs <- Monad.forM peers $ \peer -> do
        links <- fmap (Maybe.fromMaybe []) (linksRel root peer)
        sidecar <- sidecarAssetNames root peer
        pure (List.nub (DocumentLinks.assetNamesIn links ++ sidecar))
    pure (DocumentLinks.classifyAssets movingAssets peerRefs)

-- | The @.md@ pages directly beside a page (non-recursive), excluding the page itself.
siblingPages :: FilePath -> TreePath.TreePath -> IO [TreePath.TreePath]
siblingPages root self = do
    names <- Directory.listDirectory (TreePath.resolve root dir)
    pure [r | n <- names, ".md" `List.isSuffixOf` n, Just r <- [TreePath.child dir n], r /= self]
  where
    dir = TreePath.parent self

-- | The asset basenames referenced by a page's sidecar @images.yaml@/@attachments.yaml@ (local_path entries).
sidecarAssetNames :: FilePath -> TreePath.TreePath -> IO [String]
sidecarAssetNames root page = do
    imgs <- readLocalPaths (metaFs ++ "/images.yaml")
    atts <- readLocalPaths (metaFs ++ "/attachments.yaml")
    pure (imgs ++ atts)
  where
    metaFs = DocumentMeta.metaDirectoryFor root page
    readLocalPaths f = do
        exists <- Directory.doesFileExist f
        if exists then either (const []) reverse <$> Stream.foldFileTextLines (\acc line -> pure (reverse (localPathName line) ++ acc)) [] f else pure []

-- | The asset basename in a sidecar yaml line's @local_path:@ value, if it is one.
localPathName :: String -> [String]
localPathName line = case List.stripPrefix "local_path:" (dropWhile Char.isSpace line) of
    Just rest -> Maybe.maybeToList (assetBasenameOf (dropWhile Char.isSpace rest))
    Nothing -> []

-- | The basename of a same-page @assets/<name>@ reference (handling a @./@ prefix), or 'Nothing'.
assetBasenameOf :: String -> Maybe String
assetBasenameOf value = case dropWhile (== ".") (DocumentLinks.pathSegmentsOf value) of
    ("assets" : rest@(_ : _)) -> Just (List.intercalate "/" rest)
    _ -> Nothing

-- | Names whose destination @assets/@ file already holds content differing from the source asset.
assetConflicts :: FilePath -> TreePath.TreePath -> TreePath.TreePath -> [String] -> IO [String]
assetConflicts root srcAssets destAssets names =
    fmap concat $ Monad.forM names $ \name ->
        case (assetFs root srcAssets name, assetFs root destAssets name) of
            (Just sf, Just df) -> do
                srcExists <- Directory.doesFileExist sf
                destExists <- Directory.doesFileExist df
                if srcExists && destExists
                    then do
                        -- streamed, size first: neither asset is read whole (RFC-0040 phase 3);
                        -- a file that cannot be compared counts as a conflict, which refuses the move
                        same <- Stream.filesEqual sf df
                        pure [name | same /= Right True]
                    else pure []
            _ -> pure []

{- | Relocates an exclusive asset (rename) or copies a shared one to the
destination @assets/@; a name already present (identical, as conflicts are refused
beforehand) is reused. Skips an absent source.
-}
relocateOrCopyAsset :: FilePath -> TreePath.TreePath -> TreePath.TreePath -> (String, DocumentLinks.AssetClass) -> IO ()
relocateOrCopyAsset root srcAssets destAssets (name, cls) =
    case (assetFs root srcAssets name, TreePath.append destAssets name) of
        (Just sf, Just dest) -> do
            let df = TreePath.resolve root dest
            srcExists <- Directory.doesFileExist sf
            Monad.when srcExists $ do
                Directory.createDirectoryIfMissing True (TreePath.resolve root (TreePath.parent dest))
                destExists <- Directory.doesFileExist df
                if destExists
                    then pure ()
                    else case cls of
                        DocumentLinks.ExclusiveAsset -> Monad.void (FileSystem.renamePath sf df)
                        DocumentLinks.SharedAsset -> Monad.void (Stream.copyFile sf df)
        _ -> pure ()

-- | The filesystem path of @<name>@ under an assets folder, or 'Nothing' for an unsafe name.
assetFs :: FilePath -> TreePath.TreePath -> String -> Maybe FilePath
assetFs root assets name = fmap (TreePath.resolve root) (TreePath.append assets name)

-- | Co-moves a page's sidecar meta directory to follow the moved page (within or across folders).
relocateMeta :: FilePath -> TreePath.TreePath -> TreePath.TreePath -> IO ()
relocateMeta root src new = do
    let srcMeta = DocumentMeta.metaDirectoryFor root src
        destMeta = DocumentMeta.metaDirectoryFor root new
    srcExists <- Directory.doesDirectoryExist srcMeta
    destExists <- Directory.doesDirectoryExist destMeta
    -- Never clobber an existing destination meta dir (an orphan edge); only
    -- co-move when the source has one and the destination is free.
    Monad.when (srcExists && not destExists) $ do
        Directory.createDirectoryIfMissing True (TreePath.resolve root (TreePath.parent (TreePath.metaDirectory new)))
        Monad.void (FileSystem.renamePath srcMeta destMeta)

-- | The outcome of a delete: the target was moved to trash, or refused because other pages still link in.
data DeleteOutcome
    = Deleted {delTrashId :: String, delPath :: String, delKind :: String}
    | Refused {refReferrers :: [(String, String)]}
    deriving (Eq, Show)

{- | Deletes the page or section at @target@ (RFC-0027 phase 4 + RFC-0028 trash).
The target's parent index.md listing entry is not counted as a referrer (it is
removed as part of the delete); if any /other/ page still links to the target (for a
section, any page outside the subtree links into it) the delete is 'Refused' with the
referrer list and nothing is written (ADR-0063). Otherwise the target -- a page's
@.md@, sidecar meta dir, and exclusive assets, or a whole section folder -- is moved
into the trash entry @trashId@ with a provenance manifest (ADR-0065), the listing
entry removed, and 'Deleted' returned for the caller to log. @findRelevant@ supplies the
pages scanned for referrers ('scanRelevant' or 'indexRelevant').
-}
deleteTarget :: RelevantPages -> FilePath -> FilePath -> TreePath.TreePath -> TreePath.TrashId -> Int -> IO (Either String DeleteOutcome)
deleteTarget findRelevant root trashRoot target trashId seqNo
    | TreePath.isRoot target = pure (Left "cannot delete the root")
    | otherwise = do
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
                pages <- findRelevant root (RelevantQuery (BS.pack (TreePath.name target)) Nothing region)
                if isPage
                    then
                        let referrers = DocumentLinks.referrersMatching (== relPath) [parentIndexRel, relPath] pages
                         in if not (null referrers)
                                then pure (Right (Refused referrers))
                                else applyPageDelete root trashRoot target trashId seqNo
                    else
                        let inSub t = t == relPath || ((relPath ++ "/") `List.isPrefixOf` t)
                            subtreePaths = [p | (p, _) <- pages, inSub p]
                            referrers = DocumentLinks.referrersMatching inSub (parentIndexRel : subtreePaths) pages
                         in if not (null referrers)
                                then pure (Right (Refused referrers))
                                else applySectionDelete root trashRoot target trashId seqNo
  where
    fs = TreePath.resolve root target
    relPath = TreePath.render target
    isPage = TreePath.kind target == TreePath.Page
    parentIndexRel = TreePath.render (TreePath.sectionIndex (TreePath.parent target))

-- | Moves a page (its .md, sidecar meta dir, exclusive assets) to trash, removes its listing bullet, writes the manifest.
applyPageDelete :: FilePath -> FilePath -> TreePath.TreePath -> TreePath.TrashId -> Int -> IO (Either String DeleteOutcome)
applyPageDelete root trashRoot page trashId seqNo = do
    let entryDir = TreePath.trashEntryDir trashRoot trashId
        relPath = TreePath.render page
    Directory.createDirectoryIfMissing True entryDir
    assetClasses <- classifyMovingAssets root page
    let exclusives = [name | (name, DocumentLinks.ExclusiveAsset) <- assetClasses]
    mdItem <- Trash.moveIntoTrash root entryDir "page.md" page False
    metaItem <- Trash.moveDirIntoTrash root entryDir "meta" (TreePath.metaDirectory page)
    assetItems <-
        Monad.zipWithM
            (\i name -> maybe (pure Nothing) (\asset -> Trash.moveIntoTrash root entryDir ("asset-" ++ show i) asset False) (TreePath.append (TreePath.peerAssets page) name))
            [(0 :: Int) ..]
            exclusives
    removed <- removeParentListing root (TreePath.parent page) relPath
    let items = Maybe.catMaybes (mdItem : metaItem : assetItems)
    Trash.writeManifest entryDir (Trash.Manifest relPath "page" seqNo removed items)
    pure (Right (Deleted (TreePath.renderTrashId trashId) relPath "page"))

-- | Moves a whole section folder to trash, removes its listing card, writes the manifest.
applySectionDelete :: FilePath -> FilePath -> TreePath.TreePath -> TreePath.TrashId -> Int -> IO (Either String DeleteOutcome)
applySectionDelete root trashRoot section trashId seqNo = do
    let entryDir = TreePath.trashEntryDir trashRoot trashId
        relPath = TreePath.render section
    Directory.createDirectoryIfMissing True entryDir
    removed <- removeParentListing root (TreePath.parent section) (TreePath.render (TreePath.sectionIndex section))
    payloadItem <- Trash.moveIntoTrash root entryDir "payload" section True
    Trash.writeManifest entryDir (Trash.Manifest relPath "section" seqNo removed (Maybe.catMaybes [payloadItem]))
    pure (Right (Deleted (TreePath.renderTrashId trashId) relPath "section"))

{- | Restores a trash entry to its provenance path (RFC-0028), re-adding the parent
listing entry. Refuses if the original location is now occupied (prompting a new
location, like a move collision). Returns the restored @(path, kind)@ for the caller
to log a @restore@ operation.
-}
restoreFromTrash :: FilePath -> FilePath -> TreePath.TrashId -> IO (Either String (TreePath.TreePath, String))
restoreFromTrash root trashRoot trashId = do
    let entryDir = TreePath.trashEntryDir trashRoot trashId
        manifestFile = entryDir ++ "/manifest"
    hasManifest <- Directory.doesFileExist manifestFile
    -- (the manifest read below streams the file; the existence check keeps the "not found" reply distinct)
    if not hasManifest
        then pure (Left "trash entry not found")
        else do
            parsed <- Trash.readManifest entryDir
            case parsed >>= withOrigin of
                Nothing -> pure (Left "corrupt trash manifest")
                Just (manifest, origin) -> do
                    occupied <- Trash.targetOccupied root origin (Trash.manKind manifest)
                    if occupied
                        then pure (Left "original location is occupied")
                        else do
                            Monad.forM_ (Trash.manItems manifest) (Trash.restoreItem root entryDir)
                            reAddListing root origin manifest
                            Monad.void (FileSystem.removeFilePath manifestFile)
                            Monad.void (FileSystem.removeEmptyDir entryDir)
                            pure (Right (origin, Trash.manKind manifest))
  where
    withOrigin manifest = fmap (manifest,) (TreePath.parse (Trash.manPath manifest))

-- | Removes a target's entry from its parent index.md listing, returning the removed line.
removeParentListing :: FilePath -> TreePath.TreePath -> String -> IO (Maybe String)
removeParentListing root parent target = do
    txt <- readRel root parentIndex
    case txt of
        Just t -> do
            (t', removed) <- DocumentListing.removeListingEntry (TreePath.render parent) target (Utf8.decodeBytes t)
            writeRel root parentIndex (Utf8.encodeText t')
            pure removed
        Nothing -> pure Nothing
  where
    parentIndex = TreePath.sectionIndex parent

-- | Re-adds a restored item's listing entry to its parent index.md (the preserved line, or nothing when absent).
reAddListing :: FilePath -> TreePath.TreePath -> Trash.Manifest -> IO ()
reAddListing root origin manifest =
    case Trash.manListing manifest of
        Nothing -> pure ()
        Just entry -> do
            base <- fmap (maybe "" Utf8.decodeBytes) (readRel root parentIndex)
            added <- DocumentListing.addListingEntry (TreePath.render parent) target entry base
            writeRel root parentIndex (Utf8.encodeText added)
  where
    parent = TreePath.parent origin
    parentIndex = TreePath.sectionIndex parent
    target = TreePath.render (if Trash.manKind manifest == "section" then TreePath.sectionIndex origin else origin)

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
missing, destination occupied, now-referenced, a path or trash id that does not
parse) is skipped and recorded, and replay continues. A delete reuses the
operation's recorded trash id so a later restore in the log finds the entry;
replay does not append to the log.
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
    OperationLog.OpMove ->
        case (TreePath.parse from, TreePath.parse to) of
            (Just src, Just dest) -> do
                let kind = recordKind op
                -- replay-tool is a separate process with no warm index, so it uses the scan (ADR-0066).
                result <- moveTarget kind scanRelevant root src (TreePath.parent dest) (slugOf kind dest) True
                pure (movePlanStatus result)
            _ -> pure unsafePath
    OperationLog.OpDelete ->
        case (TreePath.parse from, TreePath.parseTrashId (Maybe.fromMaybe (show (OperationLog.opSeq op)) (OperationLog.opTrash op))) of
            (Just target, Just trashId) -> do
                result <- deleteTarget scanRelevant root trashRoot target trashId (OperationLog.opSeq op)
                pure $ case result of
                    Left err -> "skipped: " ++ err
                    Right (Refused _) -> "skipped: referenced"
                    Right Deleted{} -> "applied"
            _ -> pure unsafePath
    OperationLog.OpRestore ->
        case TreePath.parseTrashId (Maybe.fromMaybe "" (OperationLog.opTrash op)) of
            Just trashId -> do
                result <- restoreFromTrash root trashRoot trashId
                pure (either ("skipped: " ++) (const "applied") result)
            Nothing -> pure unsafePath
  where
    from = Maybe.fromMaybe "" (OperationLog.opFrom op)
    to = Maybe.fromMaybe "" (OperationLog.opTo op)
    unsafePath = "skipped: unsafe path or trash id"

-- | The kind an operation log record gives its target.
recordKind :: OperationLog.Operation -> TreePath.Kind
recordKind op = if OperationLog.opKind op == "page" then TreePath.Page else TreePath.Section

-- | The status word for a move result during replay.
movePlanStatus :: Either String MovePlan -> String
movePlanStatus (Left err) = "skipped: " ++ err
movePlanStatus (Right plan) = if planApplied plan then "applied" else "skipped: not applied"

-- | The wire word for an operation type.
typeWord :: OperationLog.OpType -> String
typeWord OperationLog.OpMove = "move"
typeWord OperationLog.OpDelete = "delete"
typeWord OperationLog.OpRestore = "restore"

{- | Reads the @.md@ pages /relevant/ to an operation, as @(treeRelPath, links)@, skipping
dot-entries and @assets@/@meta@ folders. A page is returned only when its raw bytes contain
@hint@ -- the target's name, which any relative link to it must contain -- or when it lies within
@subtreePrefix@ (the moved subtree, whose own pages must be rewritten even when they do not mention
the hint). Files matching neither are skipped __without unpacking or link-parsing__, which is the
difference between a sub-second and a ~90-second scan on a large corpus (no index, ADR-0059). The
byte pre-filter never drops a real referrer (false positives only cost a parse), since a relative
link's path always contains the slug/filename of what it points at.
-}
enumerateRelevant :: FilePath -> BS.ByteString -> Maybe String -> IO [(String, [DocumentLinks.Link])]
enumerateRelevant root hint subtreePrefix = walk TreePath.root
  where
    inSubtree path = case subtreePrefix of
        Nothing -> False
        Just prefix -> path == prefix || (prefix ++ "/") `List.isPrefixOf` path
    walk dir = do
        names <- Directory.listDirectory (TreePath.resolve root dir)
        fmap concat (mapM (collect dir) names)
    collect dir name
        | isDot name = pure []
        | otherwise = case TreePath.child dir name of
            Nothing -> pure []
            Just child -> do
                let childRel = TreePath.render child
                    childFs = TreePath.resolve root child
                isDir <- Directory.doesDirectoryExist childFs
                if isDir
                    then if name == "assets" || name == "meta" then pure [] else walk child
                    else
                        if ".md" `List.isSuffixOf` name
                            then do
                                -- RFC-0040 phase 6: the page is never read whole. The hint pre-filter is a
                                -- streamed substring scan (Stream.fileContains, block plus overlap), and a
                                -- relevant page's links come from the streamed scanner that linksRel uses.
                                mentioned <-
                                    if inSubtree childRel
                                        then pure True
                                        else do
                                            contained <- Stream.fileContains hint childFs
                                            pure (contained == Right True)
                                if mentioned
                                    then do
                                        links <- fmap (Maybe.fromMaybe []) (LinkIndexStore.scanPageLinks childFs)
                                        length links `seq` pure [(childRel, links)]
                                    else pure []
                            else pure []
    isDot ('.' : _) = True
    isDot _ = False

-- | A page's links, scanned as a stream; 'Nothing' when it is absent.
linksRel :: FilePath -> TreePath.TreePath -> IO (Maybe [DocumentLinks.Link])
linksRel root page = LinkIndexStore.scanPageLinks (TreePath.resolve root page)

{- | Rewrites a planned page's links in place per the decision, streaming with a
temp-then-rename write; 'Just' a reason on failure. The path comes from the planner
as a rendered path; one that does not parse is skipped.
-}
rewriteRel :: FilePath -> String -> (DocumentLinks.Link -> Maybe String) -> IO (Maybe String)
rewriteRel root rel decide =
    case TreePath.parse rel of
        Nothing -> pure Nothing
        Just page -> do
            outcome <- LinkRewrite.rewriteFileLinks decide (TreePath.resolve root page)
            pure (either (\reason -> Just ("rewrite of " ++ rel ++ " failed: " ++ reason)) (const Nothing) outcome)

-- | Reads a tree file as bytes, or 'Nothing' when it is absent.
readRel :: FilePath -> TreePath.TreePath -> IO (Maybe BS.ByteString)
readRel root path = do
    let fs = TreePath.resolve root path
    exists <- Directory.doesFileExist fs
    if exists then fmap Just (BS.readFile fs) else pure Nothing -- whole-file: index.md, bounded by formBodyLimit

-- | Writes a tree file's bytes (creating parent directories).
writeRel :: FilePath -> TreePath.TreePath -> BS.ByteString -> IO ()
writeRel root path content = do
    Directory.createDirectoryIfMissing True (TreePath.resolve root (TreePath.parent path))
    BS.writeFile (TreePath.resolve root path) content

-- | The frontmatter @name@ of an index.md (for a synthesised listing entry), or a fallback.
frontmatterNameOf :: FilePath -> IO String
frontmatterNameOf fs = fmap (Maybe.fromMaybe "Untitled" . Frontmatter.titleOf) (Frontmatter.readBlock fs)

-- | A move plan as the JSON @{"from","to","changed":[...],"applied":bool}@.
movePlanJson :: MovePlan -> Json.Json
movePlanJson plan =
    Json.object
        [ ("from", Json.string (TreePath.render (planFrom plan)))
        , ("to", Json.string (TreePath.render (planTo plan)))
        , ("changed", Json.array (map Json.string (planChanged plan)))
        , ("applied", Json.bool (planApplied plan))
        ]
