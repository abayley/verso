{- | The document tree's structural operations (RFC-0045): create, move, delete,
restore and undo, each as one transaction. An operation applies its filesystem
change through 'Verso.TreeMove', appends the operation log record (RFC-0028),
maintains the derived indexes (RFC-0029, RFC-0034), carries the page's draft
(RFC-0032) and records a revision, all under the write lock, and returns an
outcome value or a 'Refusal'. Rendering to JSON and status codes is the
handler's; nothing here knows about a request.

The collaborators are the fields of a 'Structure': the page source, the
maintenance hooks, the stores, the versioning context and the revision commit.
A test supplies recording adapters for the hooks and the commit and asserts the
transaction's effects and their order through them.
-}
module Verso.Structure (
    Structure (..),
    IndexMaintenance (..),
    noIndexMaintenance,
    combineMaintenance,
    WriteLock,
    withWriteLock,
    Versioning (..),
    noVersioning,
    defaultIdentityConfig,
    commitRevision,
    Refusal (..),
    Created (..),
    Deleted (..),
    Restored (..),
    Undone (..),
    create,
    move,
    delete,
    restore,
    undo,
    purge,
    slugify,
) where

import qualified Control.Concurrent.MVar as MVar
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.Maybe as Maybe
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Log as Log
import qualified MicroHttp.Utf8 as Utf8
import qualified System.Directory as Directory
import qualified System.IO as IO
import qualified Verso.Draft as Draft
import qualified Verso.Git as Git
import qualified Verso.Identity as Identity
import qualified Verso.OperationLog as OperationLog
import qualified Verso.OperationStore as OperationStore
import qualified Verso.TrashStore as TrashStore
import qualified Verso.TreeMove as TreeMove
import qualified Verso.TreePath as TreePath

{- | The collaborators of every structural operation: where the tree and the
trash are, the lock that serialises mutations, how the pages an operation must
inspect are found, the hooks that keep the derived indexes correct, the two
catalogues, the versioning context, and how a revision is recorded once an
operation has applied (a no-op when versioning is off).
-}
data Structure = Structure
    { structureRoot :: FilePath
    , structureTrashRoot :: FilePath
    , structureLock :: WriteLock
    , structurePages :: TreeMove.RelevantPages
    , structureMaintenance :: IndexMaintenance
    , structureOperations :: OperationStore.OperationStore
    , structureTrash :: TrashStore.TrashStore
    , structureVersioning :: Versioning
    , structureCommit :: Git.Identity -> String -> IO ()
    }

{- | Serializes the structural tree mutations (move/delete/create/undo/restore/refresh) so
concurrent requests cannot interleave their read-modify-write of the operation log and the link
index. The server is multi-threaded (a thread per connection, 'MicroHttp.Server.acceptLoop'), and
without this two concurrent moves could, e.g., read the same next op-log @seq@ and both write it
(corrupting undo), or relocate the index and the filesystem in an interleaving that leaves them
inconsistent. 'Nothing' (tests, scan mode) runs without serialization. The lock is held only across
the mutation IO, never across the request-body read.
-}
type WriteLock = Maybe (MVar.MVar ())

-- | Runs an action under the write lock when present ('Just'), or directly when absent ('Nothing', tests/scan mode).
withWriteLock :: WriteLock -> IO a -> IO a
withWriteLock Nothing act = act
withWriteLock (Just lock) act = MVar.withMVar lock (const act)

{- | The link-index maintenance hooks a tree mutation calls (RFC-0029): each keeps the
warm in-memory graph correct without a whole-tree walk. 'noIndexMaintenance' is the
no-op used without a store (tests, scan mode).
-}
data IndexMaintenance = IndexMaintenance
    { onMove :: String -> String -> IO ()
    , onDelete :: String -> IO ()
    , onCreate :: String -> IO ()
    , onRestore :: String -> IO ()
    , onSave :: String -> IO ()
    }

-- | The no-op index-maintenance hooks, used without a store (tests, scan mode).
noIndexMaintenance :: IndexMaintenance
noIndexMaintenance =
    IndexMaintenance (\_ _ -> pure ()) (const (pure ())) (const (pure ())) (const (pure ())) (const (pure ()))

-- | Runs two maintenance hook sets (link index, then search) per mutation.
combineMaintenance :: IndexMaintenance -> IndexMaintenance -> IndexMaintenance
combineMaintenance a b =
    IndexMaintenance
        { onMove = \from to -> onMove a from to >> onMove b from to
        , onDelete = \path -> onDelete a path >> onDelete b path
        , onCreate = \path -> onCreate a path >> onCreate b path
        , onRestore = \path -> onRestore a path >> onRestore b path
        , onSave = \path -> onSave a path >> onSave b path
        }

{- | The versioning context for the tree handlers (RFC-0032): whether
draft/publish versioning is on, and the draft staging root. When off, the tree
handlers behave as before (autosave writes the live page directly).
-}
data Versioning = Versioning
    { versioningOn :: Bool
    , draftStagingRoot :: FilePath
    , versioningIdentity :: Identity.IdentityConfig
    }
    deriving (Eq, Show)

-- | Versioning disabled (legacy behaviour): used by the non-versioned entry points and tests.
noVersioning :: Versioning
noVersioning = Versioning False "" defaultIdentityConfig

-- | A default identity configuration (header @X-Remote-User@, default name @anonymous@), for tests and the off case.
defaultIdentityConfig :: Identity.IdentityConfig
defaultIdentityConfig =
    Identity.IdentityConfig
        { Identity.idcHeader = "X-Remote-User"
        , Identity.idcDefault = "anonymous"
        , Identity.idcEmailDomain = "verso.local"
        }

{- | The production revision commit: commits the resulting tree state after an
applied structural operation (RFC-0032), when versioning is on. A failed commit is
logged, not fatal -- the tree mutation already succeeded and the operation log
remains the source of truth for replay. A no-op when versioning is off.
-}
commitRevision :: Versioning -> FilePath -> Git.Identity -> String -> IO ()
commitRevision versioning root author message =
    Monad.when (versioningOn versioning) $ do
        result <- Git.commitAll root author message
        case result of
            Git.CommitFailed err -> IO.hPutStrLn IO.stderr ("git commit (structural) failed: " ++ err)
            _ -> pure ()

{- | Why an operation did not apply: a reason the caller reports as text, or, for a
delete, the pages that still link to the target (ADR-0063).
-}
data Refusal
    = Refused String
    | StillReferenced [(String, String)]
    deriving (Eq, Show)

-- | A created page or section: its title, tree path, kind and the page to open for editing.
data Created = Created
    { createdTitle :: String
    , createdPath :: TreePath.TreePath
    , createdKind :: TreePath.Kind
    , createdEditPath :: TreePath.TreePath
    }
    deriving (Eq, Show)

-- | A target moved to the trash: its tree path, kind word and trash entry.
data Deleted = Deleted
    { deletedPath :: TreePath.TreePath
    , deletedKind :: String
    , deletedTrashId :: TreePath.TrashId
    }
    deriving (Eq, Show)

-- | A trash entry moved back to its origin: the path and kind word.
data Restored = Restored
    { restoredPath :: TreePath.TreePath
    , restoredKind :: String
    }
    deriving (Eq, Show)

-- | The inverse that an undo applied: a reverse move (from, to), a restore, or a delete.
data Undone
    = UndoneMove TreePath.TreePath TreePath.TreePath
    | UndoneDelete Restored
    | UndoneRestore Deleted
    deriving (Eq, Show)

{- | Creates a new page or section under a parent section (RFC-0026), writing
seeded frontmatter eagerly. The filename is a slug derived from the title, suffixed
numerically on collision; the title is preserved verbatim in the frontmatter
@name@. A section is a directory plus a seeded @index.md@. Refused for a blank
title or a missing parent.
-}
create :: Structure -> TreePath.TreePath -> TreePath.Kind -> String -> IO (Either Refusal Created)
create structure parent kind title
    | null (trimSpace title) = pure (Left (Refused "missing title"))
    | otherwise = withWriteLock (structureLock structure) $ do
        let parentFs = TreePath.resolve root parent
        parentExists <- Directory.doesDirectoryExist parentFs
        if not parentExists
            then pure (Left (Refused "parent not found"))
            else do
                slug <- uniqueSlug parentFs (slugify title) isSection
                case TreePath.child parent (if isSection then slug else slug ++ ".md") of
                    Nothing -> pure (Left (Refused "unsafe path"))
                    Just node -> do
                        let editPath = if isSection then TreePath.sectionIndex node else node
                        Monad.when isSection (Directory.createDirectoryIfMissing True (TreePath.resolve root node))
                        BS.writeFile (TreePath.resolve root editPath) (Utf8.encodeText seedBody)
                        onCreate (structureMaintenance structure) (TreePath.render editPath)
                        pure (Right (Created title node kind editPath))
  where
    root = structureRoot structure
    isSection = kind == TreePath.Section
    seedBody = "---\nname: " ++ yamlScalar title ++ "\n---\n\n# " ++ title ++ "\n"

{- | Moves a page or section (RFC-0027) under a destination parent with a slug
(the source's own when empty), previewing when @confirm@ is 'False'. An applied
move is appended to the operation log (apply-then-append, RFC-0028), relocated in
the indexes, carries its draft and is committed; a preview or a refusal changes
nothing but the tree it previews.
-}
move :: Structure -> Git.Identity -> TreePath.TreePath -> TreePath.TreePath -> String -> Bool -> IO (Either Refusal TreeMove.MovePlan)
move structure author src destParent slug confirm = withWriteLock (structureLock structure) $ do
    let isPage = TreePath.kind src == TreePath.Page
        apply = if isPage then TreeMove.movePage else TreeMove.moveSection
    result <- apply (structurePages structure) (structureRoot structure) src destParent slug confirm
    case result of
        Left reason -> pure (Left (Refused reason))
        Right plan -> do
            Monad.when (TreeMove.planApplied plan) $ do
                let from = TreeMove.planFrom plan
                    to = TreeMove.planTo plan
                appendRecord structure OperationLog.OpMove (kindWord isPage) (Just from) (Just to) Nothing
                onMove (structureMaintenance structure) (TreePath.render from) (TreePath.render to)
                relocateDraftForMove (structureVersioning structure) from to
                structureCommit structure author ("Move " ++ TreePath.render from ++ " to " ++ TreePath.render to)
            pure (Right plan)

{- | Deletes a page or section to the trash (RFC-0027 phase 4, RFC-0028): refused
with the referrers while another page links in (ADR-0063); otherwise trashed under
the delete record's @seq@, removed from the indexes, its draft stashed with the
entry, committed, logged and catalogued.
-}
delete :: Structure -> Git.Identity -> TreePath.TreePath -> IO (Either Refusal Deleted)
delete structure author target = withWriteLock (structureLock structure) $ do
    seqNo <- OperationStore.nextSeq (structureOperations structure)
    case TreePath.trashIdForSeq seqNo of
        Nothing -> pure (Left (Refused "operation log sequence is not a trash id"))
        Just trashId -> deleteInto structure author target trashId seqNo

-- | The delete transaction once the trash entry is chosen; shared with undoing a restore.
deleteInto :: Structure -> Git.Identity -> TreePath.TreePath -> TreePath.TrashId -> Int -> IO (Either Refusal Deleted)
deleteInto structure author target trashId seqNo = do
    result <- TreeMove.deleteTarget (structurePages structure) (structureRoot structure) (structureTrashRoot structure) target trashId seqNo
    case result of
        Left reason -> pure (Left (Refused reason))
        Right (TreeMove.Refused referrers) -> pure (Left (StillReferenced referrers))
        Right (TreeMove.Deleted _ _ kind) -> do
            let path = TreePath.render target
            ts <- Log.localTimestamp
            onDelete (structureMaintenance structure) path
            -- RFC-0032: stash any staged draft into the trash entry (recoverable), then commit the deletion.
            stashDraftToTrash (structureVersioning structure) (structureTrashRoot structure) target trashId
            structureCommit structure author ("Delete " ++ path)
            OperationStore.appendOperation (structureOperations structure) (record OperationLog.OpDelete kind (Just path) Nothing seqNo ts (Just (TreePath.renderTrashId trashId)))
            TrashStore.recordTrashEntry (structureTrash structure) (TrashStore.TrashEntry (TreePath.renderTrashId trashId) path kind ts)
            pure (Right (Deleted target kind trashId))

{- | Restores a trash entry to its origin (RFC-0028), re-adding the listing
entry; refused if the origin is now occupied or the entry is missing. The
restore is added to the indexes, brings back its stashed draft, is committed,
logged, and forgotten by the trash catalogue.
-}
restore :: Structure -> Git.Identity -> TreePath.TrashId -> IO (Either Refusal Restored)
restore structure author trashId = withWriteLock (structureLock structure) (restoreEntry structure author trashId)

-- | The restore transaction; shared with undoing a delete.
restoreEntry :: Structure -> Git.Identity -> TreePath.TrashId -> IO (Either Refusal Restored)
restoreEntry structure author trashId = do
    result <- TreeMove.restoreFromTrash (structureRoot structure) (structureTrashRoot structure) trashId
    case result of
        Left reason -> pure (Left (Refused reason))
        Right (restored, kind) -> do
            let path = TreePath.render restored
            onRestore (structureMaintenance structure) path
            -- RFC-0032: bring back any draft stashed with the entry, then commit the restore.
            restoreDraftFromTrash (structureVersioning structure) (structureTrashRoot structure) trashId restored
            structureCommit structure author ("Restore " ++ path)
            appendRecord structure OperationLog.OpRestore kind Nothing (Just restored) (Just trashId)
            TrashStore.forgetTrashEntry (structureTrash structure) (TreePath.renderTrashId trashId)
            pure (Right (Restored restored kind))

{- | Applies the inverse of an operation (RFC-0028) -- the reverse move, a
restore for a delete, a delete for a restore -- and appends that inverse as a new
record (undo is itself logged, so a further undo is a redo). @Just seq@ selects the
operation; 'Nothing' inverts the latest. Refused when the log is empty, the seq is
unknown, or the inverse cannot be applied (its target is occupied, missing, or now
referenced). Draft consistency through undo is not maintained (RFC-0032).
-}
undo :: Structure -> Git.Identity -> Maybe Int -> IO (Either Refusal Undone)
undo structure author wantedSeq = withWriteLock (structureLock structure) $ do
    ops <- OperationStore.readOperations (structureOperations structure)
    let chosen = case wantedSeq of
            Just s -> firstOf [op | op <- ops, OperationLog.opSeq op == s]
            Nothing -> firstOf (reverse ops)
    case chosen of
        Nothing -> pure (Left (Refused "nothing to undo"))
        Just op -> do
            result <- applyInverse structure author op
            case result of
                Right _ -> structureCommit structure author ("Undo operation " ++ show (OperationLog.opSeq op))
                Left _ -> pure ()
            pure result
  where
    firstOf (op : _) = Just op
    firstOf [] = Nothing

-- | The inverse of one logged operation, through the same move/trash machinery.
applyInverse :: Structure -> Git.Identity -> OperationLog.Operation -> IO (Either Refusal Undone)
applyInverse structure author op = case OperationLog.opType op of
    OperationLog.OpMove -> case (TreePath.parse from, TreePath.parse to) of
        (Just fromPath, Just toPath) -> do
            let isPage = OperationLog.opKind op == "page"
                apply = if isPage then TreeMove.movePage else TreeMove.moveSection
            result <- apply (structurePages structure) (structureRoot structure) toPath (TreePath.parent fromPath) (TreePath.slug fromPath) True
            case result of
                Left reason -> pure (Left (Refused reason))
                Right plan
                    | TreeMove.planApplied plan -> do
                        onMove (structureMaintenance structure) to from
                        appendRecord structure OperationLog.OpMove (OperationLog.opKind op) (Just toPath) (Just fromPath) Nothing
                        pure (Right (UndoneMove toPath fromPath))
                    | otherwise -> pure (Left (Refused "inverse move was not applied"))
        _ -> pure (Left unsafeRecord)
    OperationLog.OpDelete -> case OperationLog.opTrash op >>= TreePath.parseTrashId of
        Nothing -> pure (Left (Refused "delete record has no valid trash id"))
        Just trashId -> fmap (fmap UndoneDelete) (restoreEntryWithoutCommit trashId)
    OperationLog.OpRestore -> do
        seqNo <- OperationStore.nextSeq (structureOperations structure)
        case (TreePath.parse to, TreePath.trashIdForSeq seqNo) of
            (Just target, Just trashId) -> fmap (fmap UndoneRestore) (deleteIntoWithoutCommit target trashId seqNo)
            _ -> pure (Left unsafeRecord)
  where
    from = Maybe.fromMaybe "" (OperationLog.opFrom op)
    to = Maybe.fromMaybe "" (OperationLog.opTo op)
    unsafeRecord = Refused "operation names an unsafe path"
    -- The undo commits once, for the whole inverse, so the shared transactions run with the commit silenced.
    silenced = structure{structureCommit = \_ _ -> pure ()}
    restoreEntryWithoutCommit = restoreEntry silenced author
    deleteIntoWithoutCommit = deleteInto silenced author

{- | Permanently removes a trash entry by its raw id and forgets it in the
catalogue, returning whether it existed; an id that is not a trash id names no
entry. Nothing is logged: the log keeps the original delete, and undoing it simply
refuses once the entry is gone.
-}
purge :: Structure -> String -> IO Bool
purge structure rawId = withWriteLock (structureLock structure) $
    case TreePath.parseTrashId rawId of
        Nothing -> pure False
        Just trashId -> do
            removed <- TreeMove.deleteTrashEntry (structureTrashRoot structure) trashId
            Monad.when removed (TrashStore.forgetTrashEntry (structureTrash structure) rawId)
            pure removed

-- | Appends an operation record with a fresh @seq@ and timestamp.
appendRecord :: Structure -> OperationLog.OpType -> String -> Maybe TreePath.TreePath -> Maybe TreePath.TreePath -> Maybe TreePath.TrashId -> IO ()
appendRecord structure opType kind from to trashId = do
    seqNo <- OperationStore.nextSeq (structureOperations structure)
    ts <- Log.localTimestamp
    OperationStore.appendOperation
        (structureOperations structure)
        (record opType kind (fmap TreePath.render from) (fmap TreePath.render to) seqNo ts (fmap TreePath.renderTrashId trashId))

-- | An operation log record, the one place its fields are assembled.
record :: OperationLog.OpType -> String -> Maybe String -> Maybe String -> Int -> String -> Maybe String -> OperationLog.Operation
record opType kind from to seqNo ts trashId =
    OperationLog.Operation
        { OperationLog.opType = opType
        , OperationLog.opKind = kind
        , OperationLog.opFrom = from
        , OperationLog.opTo = to
        , OperationLog.opSeq = seqNo
        , OperationLog.opTs = ts
        , OperationLog.opTrash = trashId
        }

-- | @"page"@ or @"section"@ for the operation log.
kindWord :: Bool -> String
kindWord isPage = if isPage then "page" else "section"

{- | Relocates a moved page's (or section's) staged draft alongside the move
(RFC-0032), so a draft is not orphaned at its old tree path. A no-op when
versioning is off or there is no draft.
-}
relocateDraftForMove :: Versioning -> TreePath.TreePath -> TreePath.TreePath -> IO ()
relocateDraftForMove versioning fromPath toPath =
    Monad.when (versioningOn versioning) $ do
        let src = Draft.draftFsPath (draftStagingRoot versioning) fromPath
            dst = Draft.draftFsPath (draftStagingRoot versioning) toPath
        present <- draftPathPresent src
        Monad.when present $ do
            Directory.createDirectoryIfMissing True (Draft.draftFsPath (draftStagingRoot versioning) (TreePath.parent toPath))
            Monad.void (FileSystem.renamePath src dst)

{- | Moves a deleted page's (or section's) staged draft into the trash entry
(RFC-0032), so the draft is recoverable with the page rather than orphaned. A
no-op when versioning is off or there is no draft.
-}
stashDraftToTrash :: Versioning -> FilePath -> TreePath.TreePath -> TreePath.TrashId -> IO ()
stashDraftToTrash versioning trashRoot path tid =
    Monad.when (versioningOn versioning) $ do
        let src = Draft.draftFsPath (draftStagingRoot versioning) path
        present <- draftPathPresent src
        Monad.when present (Monad.void (FileSystem.renamePath src (trashDraftPath trashRoot tid)))

{- | Restores a trashed page's staged draft back to the draft root when its trash
entry holds one (RFC-0032), the inverse of 'stashDraftToTrash'. A no-op when
versioning is off or the entry has no draft.
-}
restoreDraftFromTrash :: Versioning -> FilePath -> TreePath.TrashId -> TreePath.TreePath -> IO ()
restoreDraftFromTrash versioning trashRoot trashId path =
    Monad.when (versioningOn versioning) $ do
        let src = trashDraftPath trashRoot trashId
            dst = Draft.draftFsPath (draftStagingRoot versioning) path
        present <- draftPathPresent src
        Monad.when present $ do
            Directory.createDirectoryIfMissing True (Draft.draftFsPath (draftStagingRoot versioning) (TreePath.parent path))
            Monad.void (FileSystem.renamePath src dst)

-- | The reserved location of a draft stashed inside a trash entry (a page draft file or a section draft subtree).
trashDraftPath :: FilePath -> TreePath.TrashId -> FilePath
trashDraftPath trashRoot tid = TreePath.trashEntryDir trashRoot tid ++ "/__draft"

-- | Whether a draft path exists as either a page draft (file) or a section draft (directory).
draftPathPresent :: FilePath -> IO Bool
draftPathPresent path = do
    isFile <- Directory.doesFileExist path
    isDir <- Directory.doesDirectoryExist path
    pure (isFile || isDir)

{- | A kebab-case filename slug from a title: lower-cased, non-alphanumeric runs
collapsed to single hyphens and trimmed, falling back to @untitled@ when nothing
remains.
-}
slugify :: String -> String
slugify title =
    case trimHyphens (collapse (map toSlugChar title)) of
        "" -> "untitled"
        s -> s
  where
    toSlugChar c
        | Char.isAsciiLower c || Char.isDigit c = c
        | Char.isAsciiUpper c = Char.toLower c
        | otherwise = '-'
    collapse ('-' : '-' : rest) = collapse ('-' : rest)
    collapse (c : rest) = c : collapse rest
    collapse [] = []
    trimHyphens = f . f where f = reverse . dropWhile (== '-')

-- | The first slug from @base@, @base-2@, @base-3@, ... not already taken in the parent folder.
uniqueSlug :: FilePath -> String -> Bool -> IO String
uniqueSlug parentFs base isSection = pick (base : [base ++ "-" ++ show n | n <- [(2 :: Int) ..]])
  where
    pick [] = pure base
    pick (candidate : rest) = do
        taken <- slugTaken parentFs candidate isSection
        if taken then pick rest else pure candidate

-- | Whether a slug is already taken in a folder (a directory for a section, a @.md@ file for a page).
slugTaken :: FilePath -> String -> Bool -> IO Bool
slugTaken parentFs slug isSection =
    if isSection
        then Directory.doesDirectoryExist (parentFs ++ "/" ++ slug)
        else Directory.doesFileExist (parentFs ++ "/" ++ slug ++ ".md")

-- | A YAML scalar for a frontmatter value: bare when safe, else double-quoted with escapes.
yamlScalar :: String -> String
yamlScalar s
    | needsQuote = "\"" ++ concatMap esc s ++ "\""
    | otherwise = s
  where
    needsQuote = null s || head s == ' ' || last s == ' ' || any special s
    special c = c == ':' || c == '#' || c == '"' || c == '\'' || c == '\n' || c == '\t'
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc c = [c]

-- | Trims leading and trailing whitespace.
trimSpace :: String -> String
trimSpace = f . f where f = reverse . dropWhile Char.isSpace
