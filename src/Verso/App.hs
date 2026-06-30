{-# LANGUAGE OverloadedStrings #-}

module Verso.App (
    DocumentStore (..),
    NodeKind (..),
    TreeNode (..),
    Versioning (..),
    noVersioning,
    app,
    appFromConfig,
    appWith,
    appWithDocumentRoot,
    appWithDocumentTree,
    appWithDocumentTreeVersioned,
    appWithStore,
    childrenOf,
    clientErrorRoute,
    documentRoutes,
    fileStore,
    frontmatterTitle,
    linkedFolderPaths,
    orderTreeNodes,
    routes,
    slugify,
    treeChildrenJson,
    treeEntryKind,
    treeRoutes,
) where

import qualified Control.Concurrent.MVar as MVar
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Log as Log
import qualified MicroHttp.Middleware as Middleware
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import qualified MicroHttp.Static as Static
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import qualified System.IO as IO
import qualified Verso.Attachment as Attachment
import qualified Verso.Config as VConfig
import qualified Verso.DocumentMeta as DocumentMeta
import qualified Verso.Draft as Draft
import qualified Verso.Git as Git
import qualified Verso.Identity as Identity
import qualified Verso.LinkIndexStore as LinkIndexStore
import qualified Verso.OperationLog as OperationLog
import qualified Verso.TreeMove as TreeMove

-- | A document store: how the flat (single-root) mode loads and saves a document by id.
data DocumentStore = DocumentStore
    { loadDocument :: String -> IO String
    , saveDocumentContent :: String -> String -> IO ()
    }

{- | The bare routed application (no middleware). 'appWith' wraps it with the
logging and error-response middleware for the running server.
-}
app :: Server.Application
app =
    appWithDocumentRoot "data/documents"

{- | The application the executable serves: the bare app wrapped with the
error-response middleware and, outermost, request logging to the given sink.
-}
appWith :: Log.Logger -> Server.Application
appWith logger =
    Middleware.logRequests logger (Middleware.withErrorResponses app)

{- | The application composed from configuration (RFC-0011): the access-log
path, document root, and static mounts come from the config, and the parse
limits from the (config-derived) settings. Logging is the outermost middleware.
-}
appFromConfig :: Server.Settings -> VConfig.VersoConfig -> IO Server.Application
appFromConfig settings vc = do
    accessLogger <- Log.rotatingFileLogfmtLogger (VConfig.logMaxBytes vc) (VConfig.logKeep vc) (VConfig.accessLog vc)
    clientErrorSink <- Log.rotatingAppender (VConfig.logMaxBytes vc) (VConfig.logKeep vc) (VConfig.clientErrorLog vc)
    -- Open the link index at startup in tree mode (RFC-0029): load the persisted index if
    -- its fingerprint still matches the tree, else build and persist. Move/delete then read
    -- it warm with no per-request walk, and re-export calls POST /index/refresh.
    indexStore <- LinkIndexStore.newLinkIndexStore
    Monad.unless (null (VConfig.documentTreeRoot vc)) $ do
        Log.consoleLog "opening link index..."
        opened <- LinkIndexStore.openLinkIndex (VConfig.documentTreeRoot vc) (VConfig.linkIndex vc) indexStore
        Log.consoleLog (either ("link index FAILED (move/delete degraded until refresh): " ++) (const "link index ready") opened)
    -- Ensure the document tree is a git repository when versioning is on (RFC-0032): a one-time
    -- import commit on first run, then reused. A missing git degrades to no versioning, not a crash.
    Monad.when (not (null (VConfig.documentTreeRoot vc)) && VConfig.versioningEnabled vc) $ do
        available <- Git.gitAvailable
        if not available
            then Log.consoleLog "versioning ON but git not found on PATH (history/publish degraded)"
            else do
                Log.consoleLog "ensuring git repository..."
                outcome <- Git.ensureRepository (VConfig.documentTreeRoot vc) (importIdentity vc)
                Log.consoleLog (case outcome of Git.Initialised -> "git repository initialised (import commit)"; Git.AlreadyPresent -> "git repository present")
    -- Serialize structural tree mutations across the server's connection threads (see 'WriteLock').
    writeLock <- MVar.newMVar ()
    pure
        ( Middleware.logRequests
            accessLogger
            ( Middleware.withErrorResponses
                ( Router.serveRoutes
                    (Server.parseLimits settings)
                    (configuredRoutes (Just writeLock) (Just indexStore) vc clientErrorSink)
                )
            )
        )

{- | The route set chosen by configuration. A non-empty @document_tree_root@
selects the filesystem-tree mode (a MkDocs-style tree served and edited in place,
with per-page peer @assets/@); otherwise the flat single-document store is used.
-}
configuredRoutes :: WriteLock -> Maybe LinkIndexStore.LinkIndexStore -> VConfig.VersoConfig -> (String -> IO ()) -> [Router.Route]
configuredRoutes writeLock indexStore vc clientErrorSink =
    clientErrorRoute clientErrorSink
        : case VConfig.documentTreeRoot vc of
            "" ->
                documentRoutes (VConfig.editorTheme vc) (VConfig.documentRoot vc)
                    ++ Attachment.attachmentRoutes (Attachment.fileAttachmentStore (VConfig.attachmentRoot vc))
                    ++ mounts
            treeRoot ->
                treeRoutes writeLock indexStore (versioningFromConfig vc) (VConfig.editorTheme vc) treeRoot (VConfig.operationLog vc) (VConfig.trashRoot vc) (VConfig.linkIndex vc) ++ mounts
  where
    mounts = [Static.static prefix root | (prefix, root) <- VConfig.staticMounts vc]

-- | The tree handlers' versioning context, read from configuration (RFC-0032).
versioningFromConfig :: VConfig.VersoConfig -> Versioning
versioningFromConfig vc =
    Versioning
        (VConfig.versioningEnabled vc)
        (VConfig.draftRoot vc)
        ( Identity.IdentityConfig
            { Identity.idcHeader = VConfig.identityHeader vc
            , Identity.idcDefault = VConfig.identityDefault vc
            , Identity.idcEmailDomain = VConfig.identityEmailDomain vc
            }
        )

-- | The author of the one-time import commit, with an email synthesised from the configured domain (RFC-0032).
importIdentity :: VConfig.VersoConfig -> Git.Identity
importIdentity vc = Git.Identity "Verso Import" ("verso@" ++ VConfig.identityEmailDomain vc)

{- | Commits the resulting tree state after an applied structural operation
(RFC-0032), when versioning is on. A failed commit is logged, not fatal -- the
tree mutation already succeeded and the operation log remains the source of truth
for replay. A no-op when versioning is off.
-}
commitStructural :: Versioning -> FilePath -> Git.Identity -> String -> IO ()
commitStructural versioning root author message =
    Monad.when (versioningOn versioning) $ do
        result <- Git.commitAll root author message
        case result of
            Git.CommitFailed err -> IO.hPutStrLn IO.stderr ("git commit (structural) failed: " ++ err)
            _ -> pure ()

{- | Relocates a moved page's (or section's) staged draft alongside the move
(RFC-0032), so a draft is not orphaned at its old tree path. A no-op when
versioning is off or there is no draft.
-}
relocateDraftForMove :: Versioning -> String -> String -> IO ()
relocateDraftForMove versioning fromPath toPath =
    Monad.when (versioningOn versioning) $ do
        let src = Draft.draftFsPath (draftStagingRoot versioning) fromPath
            dst = Draft.draftFsPath (draftStagingRoot versioning) toPath
        present <- draftPathPresent src
        Monad.when present $ do
            Directory.createDirectoryIfMissing True (parentDirectory dst)
            Monad.void (FileSystem.renamePath src dst)

{- | Moves a deleted page's (or section's) staged draft into the trash entry
(RFC-0032), so the draft is recoverable with the page rather than orphaned. A
no-op when versioning is off or there is no draft.
-}
stashDraftToTrash :: Versioning -> FilePath -> String -> String -> IO ()
stashDraftToTrash versioning trashRoot path tid =
    Monad.when (versioningOn versioning) $ do
        let src = Draft.draftFsPath (draftStagingRoot versioning) path
        present <- draftPathPresent src
        Monad.when present (Monad.void (FileSystem.renamePath src (trashDraftPath trashRoot tid)))

{- | Restores a trashed page's staged draft back to the draft root when its trash
entry holds one (RFC-0032), the inverse of 'stashDraftToTrash'. A no-op when
versioning is off or the entry has no draft.
-}
restoreDraftFromTrash :: Versioning -> FilePath -> String -> String -> IO ()
restoreDraftFromTrash versioning trashRoot trashId path =
    Monad.when (versioningOn versioning) $ do
        let src = trashDraftPath trashRoot trashId
            dst = Draft.draftFsPath (draftStagingRoot versioning) path
        present <- draftPathPresent src
        Monad.when present $ do
            Directory.createDirectoryIfMissing True (parentDirectory dst)
            Monad.void (FileSystem.renamePath src dst)

-- | The reserved location of a draft stashed inside a trash entry (a page draft file or a section draft subtree).
trashDraftPath :: FilePath -> String -> FilePath
trashDraftPath trashRoot tid = trashRoot ++ "/" ++ tid ++ "/__draft"

-- | Whether a draft path exists as either a page draft (file) or a section draft (directory).
draftPathPresent :: FilePath -> IO Bool
draftPathPresent path = do
    isFile <- Directory.doesFileExist path
    isDir <- Directory.doesDirectoryExist path
    pure (isFile || isDir)

-- | The bare flat-mode application backed by a filesystem document root.
appWithDocumentRoot :: FilePath -> Server.Application
appWithDocumentRoot root =
    appWithStore (fileStore root)

-- | A filesystem-backed document store rooted at @root@.
fileStore :: FilePath -> DocumentStore
fileStore root =
    DocumentStore
        { loadDocument = loadFileDocument root
        , saveDocumentContent = saveFileDocument root
        }

{- | The routes for a filesystem document root (the bottom of the app stack).
@editorThemeDefault@ is the visual theme the editor page emits for a first-time
visitor (one with no stored preference); see RFC-0015.
-}
documentRoutes :: String -> FilePath -> [Router.Route]
documentRoutes editorThemeDefault root =
    routes editorThemeDefault (fileStore root)

-- | The bare flat-mode application backed by a given document store (with default attachments).
appWithStore :: DocumentStore -> Server.Application
appWithStore store =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        (routes "paper" store ++ Attachment.attachmentRoutes (Attachment.fileAttachmentStore "data/attachments"))

-- | The flat single-document routes (index, show, edit, save) over a document store.
routes :: String -> DocumentStore -> [Router.Route]
routes editorThemeDefault store =
    [ Router.get "/" index
    , Router.get "/index.html" index
    , Router.get "/documents/:id/edit" (editDocument editorThemeDefault store)
    , Router.get "/documents/:id" (showDocument store)
    , Router.post "/documents/:id" (saveDocument editorThemeDefault store)
    , Static.static "/static/editor" "static/editor"
    ]

{- | The per-request versioning context for the tree handlers (RFC-0032): whether
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

{- | Routes that serve and edit a documentation tree on the filesystem. The whole
tree is reachable under @/documents/@; the editor opens at a document's own URL
with @?edit@ (so the page's base path is the file's directory and relative
@assets/...@ links resolve to the real files); a @POST@ writes the @.md@ back;
and every other tree file (images, attachments, raw Markdown) is served
statically and path-safely (reusing 'Static.resolveStaticPath'). The document id
is the tree-relative path including the @.md@ extension.
-}
treeRoutes :: WriteLock -> Maybe LinkIndexStore.LinkIndexStore -> Versioning -> String -> FilePath -> FilePath -> FilePath -> FilePath -> [Router.Route]
treeRoutes writeLock indexStore versioning editorThemeDefault root logPath trashRoot indexPath =
    [ Router.get "/" (redirectTo "/documents/")
    , Router.get "/index.html" (redirectTo "/documents/")
    , Static.static "/static/editor" "static/editor"
    , Router.get "/tree/*path" (treeChildrenHandler root)
    , Router.post "/tree/*path" (treePostDispatch versioning writeLock findRelevant maint root logPath trashRoot)
    , Router.get "/trash" (treeTrashListHandler trashRoot)
    , Router.post "/trash/*id" (treeRestoreHandler versioning writeLock maint root logPath trashRoot)
    , Router.get "/operations" (treeOperationsHandler logPath)
    , Router.post "/undo" (treeUndoHandler versioning writeLock findRelevant maint root logPath trashRoot)
    , Router.post "/index/refresh" (treeRefreshHandler writeLock refresh)
    , Router.post "/documents/*path" (treePost versioning maint root)
    , Router.get "/documents/*path" (treeGet versioning editorThemeDefault root)
    ]
  where
    -- The server backs page lookups with the warm index (no per-request walk) and
    -- maintains it incrementally after each in-server write; an explicit refresh rebuilds
    -- after a re-export. Without a store (tests, replay) the scan is used and maintenance
    -- is a no-op (RFC-0029).
    findRelevant = maybe TreeMove.scanRelevant TreeMove.indexRelevant indexStore
    maint = maybe noIndexMaintenance (storeMaintenance root) indexStore
    refresh = maybe (pure (Right ())) (LinkIndexStore.refreshLinkIndex root indexPath) indexStore

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

{- | The maintenance hooks backed by a live store: a move relocates the subtree's keys
and targets in place (pure, no re-read); a delete drops the subtree and re-reads the
parent listing; create/save re-read the written page; restore re-reads the restored
page/subtree and the parent listing. None walk the whole tree.
-}
storeMaintenance :: FilePath -> LinkIndexStore.LinkIndexStore -> IndexMaintenance
storeMaintenance root store =
    IndexMaintenance
        { onMove = \from to -> LinkIndexStore.relocateInIndex from to store
        , onDelete = \path -> LinkIndexStore.removeSubtreeInIndex path store >> reportIndexError (LinkIndexStore.applyChanges root [parentIndexPath path] store)
        , onCreate = \path -> reportIndexError (LinkIndexStore.applyChanges root [path] store)
        , onRestore = \path -> reportIndexError (LinkIndexStore.addSubtreeToIndex root path store) >> reportIndexError (LinkIndexStore.applyChanges root [parentIndexPath path] store)
        , onSave = \path -> reportIndexError (LinkIndexStore.applyChanges root [path] store)
        }
  where
    parentIndexPath p = let par = parentOfRel p in if null par then "index.md" else par ++ "/index.md"

{- | Logs an index-maintenance failure (a vanished file etc.) to stderr. The mutation
itself already succeeded; the index may be slightly stale until the next refresh, which
is the Either-policy alternative to a thrown exception killing the handler thread.
-}
reportIndexError :: IO (Either String ()) -> IO ()
reportIndexError action = do
    result <- action
    case result of
        Left err -> IO.hPutStrLn IO.stderr ("link index maintenance error: " ++ err)
        Right () -> pure ()

{- | The index refresh endpoint (RFC-0029): @POST /index/refresh@ rebuilds the link index
from the tree and re-persists it, to be called after the corpus is re-exported. A failed
rebuild is a 500 with the reason; without a store it is a 200 no-op.
-}
treeRefreshHandler :: WriteLock -> IO (Either String ()) -> Router.Handler
treeRefreshHandler writeLock refresh _ _ = do
    result <- Iteratee.liftIO (withWriteLock writeLock refresh)
    pure (either (statusResponse 500 "Internal Server Error" . (++ "\n")) (const (jsonResponse "{\"refreshed\":true}")) result)

{- | The navigation-tree children endpoint (RFC-0026): @GET /tree/*path@ returns
the immediate children of the folder at the tree-relative path (empty for the
root) as JSON, read live from the filesystem.
-}
treeChildrenHandler :: FilePath -> Router.Handler
treeChildrenHandler root captures _ = do
    nodes <- Iteratee.liftIO (childrenOf root (capture "path" captures))
    pure (jsonResponse (treeChildrenJson nodes))

-- | The maximum accepted create-request body size in bytes.
treeCreateMaxBytes :: Int
treeCreateMaxBytes = 8192

{- | The navigation-tree create endpoint (RFC-0026): @POST /tree/*path@ creates a
new page or section under the parent section at the path, from form fields @kind@
(@page@|@section@) and @title@. The file(s) are written eagerly with seeded
frontmatter; the response carries the new node and the page to open for editing,
or a @400@ for a bad request.
-}
treeCreateHandler :: WriteLock -> IndexMaintenance -> FilePath -> Router.Handler
treeCreateHandler writeLock maint root captures _ = do
    bytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) treeCreateMaxBytes
    let fields = formFields (BS.unpack bytes)
    result <- Iteratee.liftIO $
        withWriteLock writeLock $ do
            created <- createTreeNode root (capture "path" captures) (capture "kind" fields) (capture "title" fields)
            case created of
                Right (_, newPath) -> onCreate maint newPath
                Left _ -> pure ()
            pure created
    case result of
        Left err -> pure (statusResponse 400 "Bad Request" err)
        Right (response, _) -> pure response

{- | Dispatches a @POST /tree/*path@: a section/page move when the @?move@ flag is
present (RFC-0027), otherwise a create (RFC-0026).
-}
treePostDispatch :: Versioning -> WriteLock -> TreeMove.RelevantPages -> IndexMaintenance -> FilePath -> FilePath -> FilePath -> Router.Handler
treePostDispatch versioning writeLock findRelevant maint root logPath trashRoot captures request
    | hasQueryFlag "move" request = treeMoveHandler versioning author writeLock findRelevant maint root logPath captures
    | hasQueryFlag "delete" request = treeDeleteHandler versioning author writeLock findRelevant maint root logPath trashRoot captures
    | otherwise = treeCreateHandler writeLock maint root captures request
  where
    author = Identity.currentIdentity (versioningIdentity versioning) request

{- | The section-move endpoint (RFC-0027): @POST /tree/*path?move@ with form fields
@to@ (destination parent tree path), @slug@ (optional new slug), and @confirm@
(@true@ to apply, otherwise a dry-run preview). Returns the impact plan as JSON, or a
@409@ with the reason on refusal (root, cycle, collision, unsafe path).
-}
treeMoveHandler :: Versioning -> Git.Identity -> WriteLock -> TreeMove.RelevantPages -> IndexMaintenance -> FilePath -> FilePath -> Router.Captures -> Iteratee.Iter Stream.StreamError Http.Response
treeMoveHandler versioning author writeLock findRelevant maint root logPath captures = do
    bytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) treeCreateMaxBytes
    let fields = formFields (BS.unpack bytes)
        srcRel = capture "path" captures
        confirm = capture "confirm" fields == "true"
        isPage = isMarkdownPath srcRel
        move = if isPage then TreeMove.movePage else TreeMove.moveSection
    -- The whole mutation (move + op-log append + index relocate + draft relocate + commit) runs under the
    -- write lock so a concurrent move/delete cannot interleave it; the body read above stays outside the lock.
    result <- Iteratee.liftIO $
        withWriteLock writeLock $ do
            r <- move findRelevant root srcRel (capture "to" fields) (capture "slug" fields) confirm
            recordAppliedMove logPath isPage r
            maintainMove maint r -- an applied move relocates its subtree; maintain the index in place (no walk)
            case r of
                Right plan
                    | TreeMove.planApplied plan -> do
                        relocateDraftForMove versioning (TreeMove.planFrom plan) (TreeMove.planTo plan)
                        commitStructural versioning root author ("Move " ++ TreeMove.planFrom plan ++ " to " ++ TreeMove.planTo plan)
                _ -> pure ()
            pure r
    pure (either (statusResponse 409 "Conflict" . (++ "\n")) (jsonResponse . TreeMove.movePlanJson) result)

{- | Appends a @move@ record to the operation log after a move was applied
(apply-then-append, RFC-0028); a preview or a refusal logs nothing. The log's parent
directory is created on demand.
-}
recordAppliedMove :: FilePath -> Bool -> Either String TreeMove.MovePlan -> IO ()
recordAppliedMove logPath isPage (Right plan)
    | TreeMove.planApplied plan = do
        Directory.createDirectoryIfMissing True (parentDirectory logPath)
        seq' <- OperationLog.nextSeq logPath
        ts <- Log.localTimestamp
        OperationLog.appendOperation
            logPath
            OperationLog.Operation
                { OperationLog.opType = OperationLog.OpMove
                , OperationLog.opKind = if isPage then "page" else "section"
                , OperationLog.opFrom = Just (TreeMove.planFrom plan)
                , OperationLog.opTo = Just (TreeMove.planTo plan)
                , OperationLog.opSeq = seq'
                , OperationLog.opTs = ts
                , OperationLog.opTrash = Nothing
                }
recordAppliedMove _ _ _ = pure ()

-- | Relocates the moved subtree in the index, only when a move was actually applied (a preview/refusal changes nothing).
maintainMove :: IndexMaintenance -> Either String TreeMove.MovePlan -> IO ()
maintainMove maint (Right plan) | TreeMove.planApplied plan = onMove maint (TreeMove.planFrom plan) (TreeMove.planTo plan)
maintainMove _ _ = pure ()

{- | The delete endpoint (RFC-0027 phase 4 + RFC-0028 trash): @POST /tree/*path?delete@.
Refuses with @409@ and the referrer list when another page links in; otherwise moves
the target to trash, appends a @delete@ record to the operation log, and returns the
trash id. The trash id is the delete record's @seq@.
-}
treeDeleteHandler :: Versioning -> Git.Identity -> WriteLock -> TreeMove.RelevantPages -> IndexMaintenance -> FilePath -> FilePath -> FilePath -> Router.Captures -> Iteratee.Iter Stream.StreamError Http.Response
treeDeleteHandler versioning author writeLock findRelevant maint root logPath trashRoot captures = Iteratee.liftIO $ withWriteLock writeLock $ do
    let path = capture "path" captures
        isPage = isMarkdownPath path
    seqNo <- logSeq logPath
    result <- TreeMove.deleteTarget findRelevant root trashRoot path (show seqNo) seqNo
    case result of
        Left err -> pure (statusResponse 409 "Conflict" (err ++ "\n"))
        Right (TreeMove.Refused referrers) -> pure (statusResponse 409 "Conflict" (referrersJson referrers))
        Right (TreeMove.Deleted tid p _) -> do
            ts <- Log.localTimestamp
            onDelete maint p
            -- RFC-0032: stash any staged draft into the trash entry (recoverable), then commit the deletion.
            stashDraftToTrash versioning trashRoot p tid
            commitStructural versioning root author ("Delete " ++ p)
            appendOp
                logPath
                OperationLog.Operation
                    { OperationLog.opType = OperationLog.OpDelete
                    , OperationLog.opKind = kindLabel isPage
                    , OperationLog.opFrom = Just p
                    , OperationLog.opTo = Nothing
                    , OperationLog.opSeq = seqNo
                    , OperationLog.opTs = ts
                    , OperationLog.opTrash = Just tid
                    }
            pure (jsonResponse ("{\"deleted\":" ++ jsonString p ++ ",\"trashId\":" ++ jsonString tid ++ "}"))

{- | The restore endpoint (RFC-0028): @POST /trash/*id@ moves a trashed entry back to
its origin (re-adding the listing), appends a @restore@ record, and returns the
restored path; a @409@ if the origin is now occupied or the entry is missing.
-}
treeRestoreHandler :: Versioning -> WriteLock -> IndexMaintenance -> FilePath -> FilePath -> FilePath -> Router.Handler
treeRestoreHandler versioning writeLock maint root logPath trashRoot captures request = Iteratee.liftIO $ withWriteLock writeLock $ do
    let trashId = capture "id" captures
        author = Identity.currentIdentity (versioningIdentity versioning) request
    result <- TreeMove.restoreFromTrash root trashRoot trashId
    case result of
        Left err -> pure (statusResponse 409 "Conflict" (err ++ "\n"))
        Right (path, kind) -> do
            seqNo <- logSeq logPath
            ts <- Log.localTimestamp
            onRestore maint path
            -- RFC-0032: bring back any draft stashed with the entry, then commit the restore.
            restoreDraftFromTrash versioning trashRoot trashId path
            commitStructural versioning root author ("Restore " ++ path)
            appendOp
                logPath
                OperationLog.Operation
                    { OperationLog.opType = OperationLog.OpRestore
                    , OperationLog.opKind = kind
                    , OperationLog.opFrom = Nothing
                    , OperationLog.opTo = Just path
                    , OperationLog.opSeq = seqNo
                    , OperationLog.opTs = ts
                    , OperationLog.opTrash = Just trashId
                    }
            pure (jsonResponse ("{\"restored\":" ++ jsonString path ++ "}"))

-- | @"page"@ or @"section"@ for the operation log.
kindLabel :: Bool -> String
kindLabel isPage = if isPage then "page" else "section"

-- | The next operation-log sequence number, creating the log's parent directory on demand.
logSeq :: FilePath -> IO Int
logSeq logPath = do
    Directory.createDirectoryIfMissing True (parentDirectory logPath)
    OperationLog.nextSeq logPath

-- | Appends an operation to the log, creating its parent directory on demand.
appendOp :: FilePath -> OperationLog.Operation -> IO ()
appendOp logPath op = do
    Directory.createDirectoryIfMissing True (parentDirectory logPath)
    OperationLog.appendOperation logPath op

-- | A refused-delete body: the referrers as @{"refused":true,"referrers":[{"page","link"}]}@.
referrersJson :: [(String, String)] -> String
referrersJson referrers =
    "{\"refused\":true,\"referrers\":["
        ++ List.intercalate "," (map one referrers)
        ++ "]}"
  where
    one (page, link) = "{\"page\":" ++ jsonString page ++ ",\"link\":" ++ jsonString link ++ "}"

-- | The operations-list endpoint (RFC-0028): @GET /operations@ returns the log as JSON, for the undo picker.
treeOperationsHandler :: FilePath -> Router.Handler
treeOperationsHandler logPath _ _ = do
    ops <- Iteratee.liftIO (OperationLog.readOperations logPath)
    pure (jsonResponse ("[" ++ List.intercalate "," (map OperationLog.renderOperation ops) ++ "]"))

{- | The undo endpoint (RFC-0028): @POST /undo@ applies the inverse of an operation and
appends that inverse as a new record (undo is itself logged, so a further undo is a
redo). A @seq@ form field selects which operation to invert (the undo picker lists
moves and chooses one); without it, the latest operation is inverted. The inverse of a
move is the reverse move; of a delete, a restore; of a restore, a delete. A @409@ when
the log is empty, the seq is unknown, or the inverse cannot be applied (its target is
occupied, missing, or now referenced -- so inverting a non-latest move that has since
moved refuses cleanly rather than corrupting the tree).
-}
treeUndoHandler :: Versioning -> WriteLock -> TreeMove.RelevantPages -> IndexMaintenance -> FilePath -> FilePath -> FilePath -> Router.Handler
treeUndoHandler versioning writeLock findRelevant maint root logPath trashRoot _ request = do
    bytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) treeCreateMaxBytes
    let fields = formFields (BS.unpack bytes)
        wantedSeq = parseSeq (capture "seq" fields)
        author = Identity.currentIdentity (versioningIdentity versioning) request
    Iteratee.liftIO $ withWriteLock writeLock $ do
        ops <- OperationLog.readOperations logPath
        let chosen = case wantedSeq of
                Just s -> listToMaybeOp [op | op <- ops, OperationLog.opSeq op == s]
                Nothing -> listToMaybeOp (reverse ops)
        case chosen of
            Nothing -> pure (statusResponse 409 "Conflict" "nothing to undo\n")
            Just op -> do
                result <- applyInverse findRelevant maint root logPath trashRoot op
                -- RFC-0032: commit the resulting tree state when the inverse applied (draft consistency
                -- through undo is not maintained -- a known limitation noted in the RFC).
                case result of
                    Right _ -> commitStructural versioning root author ("Undo operation " ++ show (OperationLog.opSeq op))
                    Left _ -> pure ()
                pure (either (statusResponse 409 "Conflict" . (++ "\n")) jsonResponse result)

-- | The first operation of a list, if any.
listToMaybeOp :: [OperationLog.Operation] -> Maybe OperationLog.Operation
listToMaybeOp (op : _) = Just op
listToMaybeOp [] = Nothing

-- | Parses a non-negative @seq@ form value, or 'Nothing' when absent/malformed.
parseSeq :: String -> Maybe Int
parseSeq value = case reads value of
    [(n, "")] -> Just n
    _ -> Nothing

{- | Applies the inverse of an operation through the move/trash machinery and appends
the inverse record, returning the JSON body on success or an error reason.
-}
applyInverse :: TreeMove.RelevantPages -> IndexMaintenance -> FilePath -> FilePath -> FilePath -> OperationLog.Operation -> IO (Either String String)
applyInverse findRelevant maint root logPath trashRoot op = case OperationLog.opType op of
    OperationLog.OpMove -> undoMove
    OperationLog.OpDelete -> undoDelete
    OperationLog.OpRestore -> undoRestore
  where
    from = Maybe.fromMaybe "" (OperationLog.opFrom op)
    to = Maybe.fromMaybe "" (OperationLog.opTo op)

    undoMove = do
        let destParent = parentOfRel from
            slug = slugForPath (OperationLog.opKind op) from
            move = if OperationLog.opKind op == "page" then TreeMove.movePage else TreeMove.moveSection
        result <- move findRelevant root to destParent slug True
        case result of
            Left err -> pure (Left err)
            Right plan
                | TreeMove.planApplied plan -> do
                    onMove maint to from
                    appendInverse (OperationLog.opKind op) OperationLog.OpMove (Just to) (Just from) Nothing
                    pure (Right ("{\"undo\":\"move\",\"from\":" ++ jsonString to ++ ",\"to\":" ++ jsonString from ++ "}"))
                | otherwise -> pure (Left "inverse move was not applied")

    undoDelete = case OperationLog.opTrash op of
        Nothing -> pure (Left "delete record has no trash id")
        Just tid -> do
            result <- TreeMove.restoreFromTrash root trashRoot tid
            case result of
                Left err -> pure (Left err)
                Right (path, kind) -> do
                    onRestore maint path
                    appendInverse kind OperationLog.OpRestore Nothing (Just path) (Just tid)
                    pure (Right ("{\"undo\":\"delete\",\"restored\":" ++ jsonString path ++ "}"))

    undoRestore = do
        seqNo <- logSeq logPath
        result <- TreeMove.deleteTarget findRelevant root trashRoot to (show seqNo) seqNo
        case result of
            Left err -> pure (Left err)
            Right (TreeMove.Refused _) -> pure (Left "cannot undo restore: the target is now referenced")
            Right (TreeMove.Deleted tid path _) -> do
                ts <- Log.localTimestamp
                onDelete maint to
                appendOp logPath (OperationLog.Operation OperationLog.OpDelete (kindOf to) (Just path) Nothing seqNo ts (Just tid))
                pure (Right ("{\"undo\":\"restore\",\"deleted\":" ++ jsonString path ++ ",\"trashId\":" ++ jsonString tid ++ "}"))

    -- Appends an inverse record with a fresh seq and timestamp.
    appendInverse kind typ opFrom' opTo' trash = do
        seqNo <- logSeq logPath
        ts <- Log.localTimestamp
        appendOp
            logPath
            OperationLog.Operation
                { OperationLog.opType = typ
                , OperationLog.opKind = kind
                , OperationLog.opFrom = opFrom'
                , OperationLog.opTo = opTo'
                , OperationLog.opSeq = seqNo
                , OperationLog.opTs = ts
                , OperationLog.opTrash = trash
                }

-- | The trash listing endpoint (RFC-0028): @GET /trash@ returns the trash entries as JSON for the Trash view.
treeTrashListHandler :: FilePath -> Router.Handler
treeTrashListHandler trashRoot _ _ = do
    entries <- Iteratee.liftIO (TreeMove.listTrash trashRoot)
    pure (jsonResponse (TreeMove.trashListJson entries))

-- Replay is an operator action run from the @replay-tool@ CLI (RFC-0028), not a web
-- endpoint, so it is deliberately not surfaced under the routes; the logic lives in
-- 'Verso.TreeMove.replayLog'.

-- | @"page"@ or @"section"@ for a tree path.
kindOf :: String -> String
kindOf path = kindLabel (isMarkdownPath path)

-- | The parent tree path of a tree path (its segments minus the last; @""@ at the root).
parentOfRel :: String -> String
parentOfRel path = List.intercalate "/" (initOrEmpty (pathSegments path))
  where
    initOrEmpty [] = []
    initOrEmpty xs = init xs

-- | The destination slug to move a path back to: a page's basename without @.md@, a section's last segment.
slugForPath :: String -> String -> String
slugForPath kind path =
    let name = lastOrEmpty (pathSegments path)
     in if kind == "page" && ".md" `List.isSuffixOf` name then take (length name - length ".md") name else name
  where
    lastOrEmpty [] = ""
    lastOrEmpty xs = last xs

-- | A handler that redirects to a fixed location (a @303 See Other@ to a GET target).
redirectTo :: String -> Router.Handler
redirectTo location _ _ = pure (seeOtherResponse location)

-- | The bare tree-serving application (no middleware), for tests and embedding.
appWithDocumentTree :: String -> FilePath -> Server.Application
appWithDocumentTree editorThemeDefault root =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        (treeRoutes Nothing Nothing noVersioning editorThemeDefault root "data/operation_log" "data/trash" "data/link_index")

-- | A tree-mode app with draft/publish versioning on and drafts staged under @draftRoot@ (RFC-0032; tests).
appWithDocumentTreeVersioned :: String -> FilePath -> FilePath -> Server.Application
appWithDocumentTreeVersioned editorThemeDefault root draftRoot =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        (treeRoutes Nothing Nothing (Versioning True draftRoot defaultIdentityConfig) editorThemeDefault root "data/operation_log" "data/trash" "data/link_index")

{- | A GET under the tree: the editor page for @?edit@ on a Markdown file,
otherwise the file served statically (raw Markdown, images, attachments).
-}
treeGet :: Versioning -> String -> FilePath -> Router.Handler
treeGet versioning editorThemeDefault root captures request
    | not (isMarkdownPath path) = treeServeFile root path
    | hasQueryFlag "history" request = treeHistory editorThemeDefault root path
    | hasQueryFlag "diff" request = treeDiff editorThemeDefault root path request
    | hasQueryFlag "edit" request = treeEdit versioning editorThemeDefault root path request
    | hasQueryFlag "raw" request = treeServeFile root path
    | otherwise = treeRead versioning editorThemeDefault root path request
  where
    -- The tree root (@/documents@ or @/documents/@) resolves to its @index.md@ page.
    path = case capture "path" captures of
        "" -> "index.md"
        captured -> captured

{- | Renders the editable editor for a tree document, loading its current content
(or a seed if the file is absent, so a missing page can be created by editing).
-}
treeEdit :: Versioning -> String -> FilePath -> String -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
treeEdit versioning editorThemeDefault root path request =
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            -- Resume a staged draft if one exists (RFC-0032); otherwise the published page, or a seed.
            mDraft <-
                if versioningOn versioning
                    then Iteratee.liftIO (Draft.readDraft (draftStagingRoot versioning) path)
                    else pure Nothing
            content <- case mDraft of
                Just drafted -> pure drafted
                Nothing -> do
                    exists <- Iteratee.liftIO (Directory.doesFileExist fsPath)
                    if exists then Iteratee.liftIO (BS.readFile fsPath) else pure (BS.pack seededMarkdown)
            attachments <- Iteratee.liftIO (loadPageAttachments root path)
            breadcrumbs <- Iteratee.liftIO (breadcrumbsFor root path (BS.unpack content))
            spine <- Iteratee.liftIO (treeSpineFor root path)
            pure (documentResponse (editorPage path (editorMode request) editorThemeDefault content True True (Maybe.isJust mDraft) attachments breadcrumbs spine Nothing))

{- | Renders the read-only view for a tree document (the default @GET@, RFC-0020):
the editor shell with editing disabled. A missing page is a @404@ -- reading never
seeds (that stays an @?edit@ affordance).
-}
treeRead :: Versioning -> String -> FilePath -> String -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
treeRead versioning editorThemeDefault root path request =
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            exists <- Iteratee.liftIO (Directory.doesFileExist fsPath)
            if not exists
                then pure treeNotFound
                else do
                    content <- Iteratee.liftIO (BS.readFile fsPath)
                    attachments <- Iteratee.liftIO (loadPageAttachments root path)
                    breadcrumbs <- Iteratee.liftIO (breadcrumbsFor root path (BS.unpack content))
                    spine <- Iteratee.liftIO (treeSpineFor root path)
                    -- RFC-0032: flag an unpublished draft so the read view can mark it next to "Edit".
                    hasDraft <-
                        if versioningOn versioning
                            then Iteratee.liftIO (Draft.hasDraft (draftStagingRoot versioning) path)
                            else pure False
                    pure (documentResponse (editorPage path (editorMode request) editorThemeDefault content True False hasDraft attachments breadcrumbs spine Nothing))

-- | Serves a tree file as a sized 'FileBody' with a type from its extension, or a @404@ when absent.
treeServeFile :: FilePath -> String -> Iteratee.Iter Stream.StreamError Http.Response
treeServeFile root path =
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            exists <- Iteratee.liftIO (Directory.doesFileExist fsPath)
            if not exists
                then pure treeNotFound
                else do
                    sized <- Iteratee.liftIO (Socket.fileSizeBytes fsPath)
                    case sized of
                        Nothing -> pure treeNotFound
                        Just size ->
                            pure
                                ( Http.Response
                                    Http.okStatus
                                    [contentTypeHeader (Static.contentTypeFor fsPath)]
                                    (Http.FileBody fsPath size)
                                )

{- | A POST under the tree: an asset upload (@?asset@, a raw-body file) into the
document's peer @assets/@ folder, or otherwise a document save.
-}
treePost :: Versioning -> IndexMaintenance -> FilePath -> Router.Handler
treePost versioning maint root captures request
    | hasQueryFlag "asset" request = treeUpload root captures request
    | hasQueryFlag "publish" request = treePublish versioning maint root captures request
    | hasQueryFlag "discard-draft" request = treeDiscard versioning root captures request
    | hasQueryFlag "rollback" request = treeRollback versioning maint root captures request
    | otherwise = treeSave versioning maint root captures request

-- | The maximum accepted tree asset upload size in bytes.
treeAssetMaxBytes :: Int
treeAssetMaxBytes = 10485760

{- | Receives a raw-body file upload and stores it in the editing document's peer
@assets/@ folder under a meaningful, sanitised filename (from the
@X-Attachment-Filename@ header), de-duplicating within the folder and suffixing on
a name collision with different content. Returns @{"url":"assets/<name>"}@ -- a
page-relative reference the editor inserts, matching the tree's layout.
-}
treeUpload :: FilePath -> Router.Handler
treeUpload root captures request = do
    bytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) treeAssetMaxBytes
    let path = capture "path" captures
        name = Attachment.uploadFilename request
    if not (Attachment.allowedExtension (Attachment.extensionOf name))
        then pure (statusResponse 415 "Unsupported Media Type" "attachment type is not allowed\n")
        else case assetsDirectoryFor root path of
            Nothing -> pure treeNotFound
            Just assetsDir -> do
                Iteratee.liftIO (Directory.createDirectoryIfMissing True assetsDir)
                stored <- Iteratee.liftIO (storeAsset assetsDir name bytes)
                Iteratee.liftIO (recordAssetMetadata root path stored (Attachment.originalUploadFilename request))
                pure (jsonResponse ("{\"url\":\"assets/" ++ stored ++ "\"}"))

{- | Record a freshly stored asset in the page's sidecar metadata (ADR-049): an
inline image in @images.yaml@ (with the original filename as its initial
@short_title@), anything else in @attachments.yaml@. Classification reuses the
attachment store's @inlineImageExtension@. A no-op when the document path is
unsafe (the upload itself has already been path-validated).
-}
recordAssetMetadata :: FilePath -> String -> String -> String -> IO ()
recordAssetMetadata root path stored originalName =
    case DocumentMeta.metaDirectoryFor root path of
        Nothing -> pure ()
        Just metaDir
            | Attachment.inlineImageExtension extension -> DocumentMeta.appendImage metaDir localPath originalName
            | otherwise -> DocumentMeta.appendAttachment metaDir (DocumentMeta.AttachmentEntry originalName localPath extension)
  where
    localPath = "assets/" ++ stored
    extension = Attachment.extensionOf stored

{- | The peer @assets/@ directory of a tree document, or 'Nothing' if the document
path is unsafe. The path is validated as a tree-relative file; its directory's
@assets/@ sibling is where the page's images and attachments live.
-}
assetsDirectoryFor :: FilePath -> String -> Maybe FilePath
assetsDirectoryFor root path =
    fmap (\fsPath -> parentDirectory fsPath ++ "/assets") (Static.resolveStaticPath root (pathSegments path))

-- | The page's recorded attachments as @(name, local_path)@ pairs for the metadata panel, or @[]@.
loadPageAttachments :: FilePath -> String -> IO [(String, String)]
loadPageAttachments root path =
    maybe (pure []) DocumentMeta.readAttachmentEntries (DocumentMeta.metaDirectoryFor root path)

{- | Stores bytes in an assets folder under a meaningful name, returning the name
actually used. An identical file already present is reused (dedup); a name taken
by different content is suffixed (@diagram.png@ -> @diagram-2.png@ -> ...).
-}
storeAsset :: FilePath -> String -> BS.ByteString -> IO String
storeAsset assetsDir name bytes =
    tryCandidate (candidateNames name)
  where
    tryCandidate [] = do
        BS.writeFile (assetsDir ++ "/" ++ name) bytes
        pure name
    tryCandidate (candidate : rest) = do
        let target = assetsDir ++ "/" ++ candidate
        exists <- Directory.doesFileExist target
        if not exists
            then do
                BS.writeFile target bytes
                pure candidate
            else do
                existing <- BS.readFile target
                if existing == bytes
                    then pure candidate
                    else tryCandidate rest

{- | A filename and its collision-suffixed alternatives: @x.png@, @x-2.png@,
@x-3.png@, ... (the suffix goes before the extension).
-}
candidateNames :: String -> [String]
candidateNames name =
    name : [base ++ "-" ++ show n ++ ext | n <- [(2 :: Int) ..]]
  where
    (base, ext) = splitExtension name

{- | Splits a filename into its base and extension (the last @.@ onward), or an
empty extension when there is none.
-}
splitExtension :: String -> (String, String)
splitExtension name =
    case break (== '.') (reverse name) of
        (revExt, '.' : revBase) -> (reverse revBase, '.' : reverse revExt)
        (_, _) -> (name, "")

{- | The page's attachments as a compact JSON array of @{"name","localPath"}@
objects, embedded on the editor element for the metadata panel (RFC-0019). Strings
are JSON-escaped; the surrounding HTML attribute is escaped by the renderer.
-}
attachmentsJson :: [(String, String)] -> String
attachmentsJson entries = "[" ++ List.intercalate "," (map attachmentObject entries) ++ "]"
  where
    attachmentObject (name, localPath) =
        "{\"name\":" ++ jsonString name ++ ",\"localPath\":" ++ jsonString localPath ++ "}"

-- | A JSON string literal: the value wrapped in quotes with the structural characters escaped.
jsonString :: String -> String
jsonString s = "\"" ++ concatMap escape s ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape c = [c]

-- | A breadcrumb in the path navigation: a visible label and an optional link (Nothing for the current page).
data Crumb = Crumb String (Maybe String)

{- | The folder rel-paths whose @index.md@ pages link in a document's breadcrumb trail, root-first and
excluding the current page (the trail's final, unlinked crumb). A folder index page contributes its folder as
the current crumb, so it is not also linked: @"a/b/page.md"@ links @["", "a", "a/b"]@; @"a/index.md"@ links
@["", "a"]@; @"a/page.md"@ links @["", "a"]@; the root @"index.md"@ links @[]@ (it is the current page).
-}
linkedFolderPaths :: String -> [String]
linkedFolderPaths path
    | isIndex && null dirSegs = []
    | otherwise = "" : scanl1 joinSeg folderSegs
  where
    segs = pathSegments path
    isIndex = not (null segs) && last segs == "index.md"
    dirSegs = if null segs then [] else init segs
    folderSegs = if isIndex then dropLast dirSegs else dirSegs
    dropLast xs = if null xs then [] else init xs
    joinSeg acc s = acc ++ "/" ++ s

{- | The link target for a folder rel-path: its @index.md@ page (a directory URL is not itself routable, so
the trail links the explicit index document). Root is @/documents/index.md@, @"a/b"@ is @/documents/a/b/index.md@.
-}
folderHref :: String -> String
folderHref "" = "/documents/index.md"
folderHref fp = "/documents/" ++ fp ++ "/index.md"

{- | Builds a document's breadcrumb trail: each ancestor folder's @index.md@ title as a link, then the
current page's own title as the final unlinked crumb. A folder's label falls back to a humanised segment
(and the root to @Cello@) when its @index.md@ is missing or has no @name@.
-}
breadcrumbsFor :: FilePath -> String -> String -> IO [Crumb]
breadcrumbsFor root path content = do
    links <- mapM folderCrumb (linkedFolderPaths path)
    pure (links ++ [Crumb currentLabel Nothing])
  where
    folderCrumb fp = do
        name <- readIndexTitle root fp
        pure (Crumb (Maybe.fromMaybe (folderFallback fp) name) (Just (folderHref fp)))
    folderFallback "" = "Cello"
    folderFallback fp = humaniseSegment (lastSegment fp)
    currentLabel = Maybe.fromMaybe (humaniseSegment (lastSegment path)) (frontmatterTitle content)

-- | The last @/@-separated segment of a path (the path itself when it has none).
lastSegment :: String -> String
lastSegment p = case pathSegments p of
    [] -> p
    segs -> last segs

-- | A fallback label from a path segment: hyphens and underscores to spaces, each word capitalised.
humaniseSegment :: String -> String
humaniseSegment = unwords . map capitalise . words . map spacer . dropExtension
  where
    spacer c = if c == '-' || c == '_' then ' ' else c
    capitalise [] = []
    capitalise (c : cs) = Char.toUpper c : cs
    dropExtension s = if ".md" `List.isSuffixOf` s then take (length s - 3) s else s

-- | Reads a folder's @index.md@ frontmatter title, or Nothing when the file is absent or untitled.
readIndexTitle :: FilePath -> String -> IO (Maybe String)
readIndexTitle root fp =
    case Static.resolveStaticPath root (pathSegments indexPath) of
        Nothing -> pure Nothing
        Just fsPath -> do
            exists <- Directory.doesFileExist fsPath
            if exists
                then fmap frontmatterTitle (readDocumentText fsPath)
                else pure Nothing
  where
    indexPath = if null fp then "index.md" else fp ++ "/index.md"

-- | The @name@ field from a document's leading @---@ frontmatter block (unquoted), or Nothing.
frontmatterTitle :: String -> Maybe String
frontmatterTitle content =
    case map stripCarriageReturn (lines content) of
        (first : rest)
            | trimSpace first == "---" -> findName (takeWhile (\l -> trimSpace l /= "---") rest)
        _ -> Nothing
  where
    findName [] = Nothing
    findName (l : ls) = case nameFieldValue l of
        Just value -> Just value
        Nothing -> findName ls

-- | The unquoted value of a @name:@ line, or Nothing for any other line.
nameFieldValue :: String -> Maybe String
nameFieldValue line = case break (== ':') (dropWhile Char.isSpace (stripCarriageReturn line)) of
    ("name", ':' : rest) -> Just (unquoteScalar (trimSpace rest))
    _ -> Nothing

-- | Strips a surrounding double- or single-quoted YAML scalar, unescaping as that style requires.
unquoteScalar :: String -> String
unquoteScalar value
    | wrapped '"' = unescapeDouble middle
    | wrapped '\'' = undoubleSingle middle
    | otherwise = value
  where
    wrapped q = length value >= 2 && head value == q && last value == q
    middle = init (drop 1 value)
    unescapeDouble ('\\' : c : xs) = c : unescapeDouble xs
    unescapeDouble (c : xs) = c : unescapeDouble xs
    unescapeDouble [] = []
    undoubleSingle ('\'' : '\'' : xs) = '\'' : undoubleSingle xs
    undoubleSingle (c : xs) = c : undoubleSingle xs
    undoubleSingle [] = []

-- | Trims leading and trailing whitespace.
trimSpace :: String -> String
trimSpace = f . f where f = reverse . dropWhile Char.isSpace

-- | Drops a trailing carriage return (CRLF tolerance).
stripCarriageReturn :: String -> String
stripCarriageReturn s = if not (null s) && last s == '\r' then init s else s

-- | The breadcrumb trail as a JSON array of @{"label","href"}@ (href omitted for the current page).
breadcrumbsJson :: [Crumb] -> String
breadcrumbsJson crumbs = "[" ++ List.intercalate "," (map crumbObject crumbs) ++ "]"
  where
    crumbObject (Crumb label href) =
        "{\"label\":" ++ jsonString label ++ maybe "" (\h -> ",\"href\":" ++ jsonString h) href ++ "}"

-- | A navigation-tree node kind: a section (a folder) or a page (a Markdown file).
data NodeKind = Section | Page
    deriving (Eq, Show)

{- | A navigation-tree node (RFC-0026): a section or page with its display label,
tree-relative path (a section's directory path, a page's @.md@ path), and whether a
section has expandable children.
-}
data TreeNode = TreeNode
    { nodeName :: String
    , nodePath :: String
    , nodeKind :: NodeKind
    , nodeHasChildren :: Bool
    }
    deriving (Eq, Show)

{- | Classifies a raw directory entry for the navigation tree, or 'Nothing' when it
is hidden: the sidecar @meta@/peer-@assets@ folders, dotfiles, non-Markdown files,
and a folder's own @index.md@ (folded into its section, ADR-058/ADR-059, not shown
as a child).
-}
treeEntryKind :: String -> Bool -> Maybe NodeKind
treeEntryKind name isDir
    | isHidden = Nothing
    | isDir = Just Section
    | name == "index.md" = Nothing
    | isMarkdownPath name = Just Page
    | otherwise = Nothing
  where
    isHidden = isDotfile || name == "meta" || name == "assets"
    isDotfile = case name of
        ('.' : _) -> True
        _ -> False

{- | Orders sibling nodes for display (RFC-0026): sections before pages,
alphabetical by label (case-insensitively) within each group.
-}
orderTreeNodes :: [TreeNode] -> [TreeNode]
orderTreeNodes = List.sortBy compareNodes
  where
    compareNodes a b = compare (sortKey a) (sortKey b)
    sortKey n = (kindRank (nodeKind n), map Char.toLower (nodeName n))
    kindRank :: NodeKind -> Int
    kindRank Section = 0
    kindRank Page = 1

-- | The navigation-tree children as a JSON array of @{"name","path","kind","hasChildren"}@ (RFC-0026).
treeChildrenJson :: [TreeNode] -> String
treeChildrenJson nodes = "[" ++ List.intercalate "," (map nodeObject nodes) ++ "]"
  where
    nodeObject n =
        "{\"name\":"
            ++ jsonString (nodeName n)
            ++ ",\"path\":"
            ++ jsonString (nodePath n)
            ++ ",\"kind\":"
            ++ jsonString (kindString (nodeKind n))
            ++ ",\"hasChildren\":"
            ++ (if nodeHasChildren n then "true" else "false")
            ++ "}"
    kindString Section = "section"
    kindString Page = "page"

{- | The immediate navigation-tree children of a folder (its tree-relative path,
empty for the root), read live from the filesystem and ordered for display
(RFC-0026, ADR-059). Returns @[]@ for an unsafe path or a missing directory.
-}
childrenOf :: FilePath -> String -> IO [TreeNode]
childrenOf root parentRel =
    case Static.resolveStaticPath root (pathSegments parentRel) of
        Nothing -> pure []
        Just dirFs -> do
            isDir <- Directory.doesDirectoryExist dirFs
            if not isDir
                then pure []
                else do
                    names <- Directory.listDirectory dirFs
                    nodes <- mapM (childNode root parentRel dirFs) names
                    pure (orderTreeNodes (Maybe.catMaybes nodes))

-- | Builds a navigation-tree node for one directory entry, or 'Nothing' when it is hidden.
childNode :: FilePath -> String -> FilePath -> String -> IO (Maybe TreeNode)
childNode root parentRel dirFs name = do
    isDir <- Directory.doesDirectoryExist entryFs
    case treeEntryKind name isDir of
        Nothing -> pure Nothing
        Just Section -> do
            label <- sectionLabel root childRel name
            hasKids <- dirHasVisibleChildren entryFs
            pure (Just (TreeNode label childRel Section hasKids))
        Just Page -> do
            label <- pageLabel root childRel name
            pure (Just (TreeNode label childRel Page False))
  where
    entryFs = dirFs ++ "/" ++ name
    childRel = if null parentRel then name else parentRel ++ "/" ++ name

-- | A section's label: its @index.md@ frontmatter @name@, or a humanised directory segment.
sectionLabel :: FilePath -> String -> String -> IO String
sectionLabel root childRel name = do
    title <- readIndexTitle root childRel
    pure (Maybe.fromMaybe (humaniseSegment name) title)

-- | A page's label: its frontmatter @name@, or a humanised filename.
pageLabel :: FilePath -> String -> String -> IO String
pageLabel root childRel name =
    case Static.resolveStaticPath root (pathSegments childRel) of
        Nothing -> pure (humaniseSegment name)
        Just fsPath -> do
            exists <- Directory.doesFileExist fsPath
            if not exists
                then pure (humaniseSegment name)
                else do
                    title <- fmap frontmatterTitle (readDocumentText fsPath)
                    pure (Maybe.fromMaybe (humaniseSegment name) title)

-- | Whether a folder holds any entry the navigation tree would show (so a section is expandable).
dirHasVisibleChildren :: FilePath -> IO Bool
dirHasVisibleChildren dirFs = do
    names <- Directory.listDirectory dirFs
    anyVisible names
  where
    anyVisible [] = pure False
    anyVisible (n : ns) = do
        isDir <- Directory.doesDirectoryExist (dirFs ++ "/" ++ n)
        case treeEntryKind n isDir of
            Just _ -> pure True
            Nothing -> anyVisible ns

{- | The navigation-tree spine for the open page (RFC-0026): the children of each
ancestor folder, root-first, so the client opens the tree pre-expanded to the page
without load-time fetches. A JSON array of @{"path","children":[...]}@; the root
is always present even for the root @index.md@.
-}
treeSpineFor :: FilePath -> String -> IO String
treeSpineFor root path = do
    entries <- mapM folderEntry spineFolders
    pure ("[" ++ List.intercalate "," entries ++ "]")
  where
    spineFolders = case linkedFolderPaths path of
        [] -> [""]
        fps -> fps
    folderEntry fp = do
        nodes <- childrenOf root fp
        pure ("{\"path\":" ++ jsonString fp ++ ",\"children\":" ++ treeChildrenJson nodes ++ "}")

{- | Creates a new page or section under a parent section (RFC-0026), writing
seeded frontmatter eagerly, and returns either an error message ('Left', a @400@)
or the created-node JSON response ('Right'). The filename is a slug derived from
the title, suffixed numerically on collision; the title is preserved verbatim in
the frontmatter @name@. A section is a directory plus a seeded @index.md@.
-}
createTreeNode :: FilePath -> String -> String -> String -> IO (Either String (Http.Response, String))
createTreeNode root parentRel kind title
    | null (trimSpace title) = pure (Left "missing title\n")
    | kind /= "page" && kind /= "section" = pure (Left "unknown kind\n")
    | otherwise =
        case Static.resolveStaticPath root (pathSegments parentRel) of
            Nothing -> pure (Left "unsafe path\n")
            Just parentFs -> do
                parentExists <- Directory.doesDirectoryExist parentFs
                if not parentExists
                    then pure (Left "parent not found\n")
                    else do
                        slug <- uniqueSlug parentFs (slugify title) (kind == "section")
                        let childRel = joinRel parentRel slug
                            seedBody = "---\nname: " ++ yamlScalar title ++ "\n---\n\n# " ++ title ++ "\n"
                        if kind == "section"
                            then do
                                Directory.createDirectoryIfMissing True (parentFs ++ "/" ++ slug)
                                writeDocumentText (parentFs ++ "/" ++ slug ++ "/index.md") seedBody
                                pure (Right (jsonResponse (createdJson title childRel "section" (childRel ++ "/index.md")), childRel ++ "/index.md"))
                            else do
                                writeDocumentText (parentFs ++ "/" ++ slug ++ ".md") seedBody
                                pure (Right (jsonResponse (createdJson title (childRel ++ ".md") "page" (childRel ++ ".md")), childRel ++ ".md"))

-- | Joins a parent tree-relative path and a child segment (the segment alone at the root).
joinRel :: String -> String -> String
joinRel "" s = s
joinRel p s = p ++ "/" ++ s

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

-- | The created-node JSON: the display name, tree path, kind, and the page path to open for editing.
createdJson :: String -> String -> String -> String -> String
createdJson name path kind editPath =
    "{\"name\":"
        ++ jsonString name
        ++ ",\"path\":"
        ++ jsonString path
        ++ ",\"kind\":"
        ++ jsonString kind
        ++ ",\"editPath\":"
        ++ jsonString editPath
        ++ "}"

-- | A @200@ JSON response with the given body.
jsonResponse :: String -> Http.Response
jsonResponse body =
    Http.Response Http.okStatus [contentTypeHeader "application/json"] (Http.StrictBody (BS.pack body))

-- | A plain-text response with the given status code, reason, and body.
statusResponse :: Int -> String -> String -> Http.Response
statusResponse code reason body =
    Http.Response (Http.Status code reason) [contentTypeHeader "text/plain"] (Http.StrictBody (BS.pack body))

-- | The maximum accepted client-error report size in bytes (RFC-0023).
clientErrorMaxBytes :: Int
clientErrorMaxBytes = 8192

{- | The client-error telemetry endpoint (RFC-0023, ADR-052): a fire-and-forget
@POST /client-errors@ that records one bounded, escaped logfmt line via the given
sink (the rotating client-error log) and returns @204@. A deliberate, write-only
exception to the store-and-serve server (ADR-019); the report carries no document
content and no user identity.
-}
clientErrorRoute :: (String -> IO ()) -> Router.Route
clientErrorRoute sink = Router.post "/client-errors" (clientErrorHandler sink)

-- | Records one bounded client-error report via the sink and answers @204@.
clientErrorHandler :: (String -> IO ()) -> Router.Handler
clientErrorHandler sink _ request = do
    bytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) clientErrorMaxBytes
    let fields = formFields (BS.unpack bytes)
    Iteratee.liftIO $ do
        ts <- Log.localTimestamp
        sink (clientErrorLine ts request fields)
    pure (Http.Response (Http.Status 204 "No Content") [] (Http.StrictBody (BS.pack "")))

{- | One logfmt line for a client-error report: the server-stamped timestamp,
peer, and user-agent, plus the bounded, escaped client fields. Client values are
quoted and escaped (unlike the access log's server-controlled values) so a
crafted message or stack cannot break the line or inject fields.
-}
clientErrorLine :: String -> Http.RequestHead -> [(String, String)] -> String
clientErrorLine ts request fields =
    "ts="
        ++ ts
        ++ " event=CLERR peer="
        ++ clientPeerHost (Http.requestPeer request)
        ++ " kind="
        ++ clientErrorKind (capture "kind" fields)
        ++ " path="
        ++ logfmtValue (take 300 (capture "path" fields))
        ++ " ua="
        ++ logfmtValue (take 300 (requestUserAgent request))
        ++ " message="
        ++ logfmtValue (take 500 (capture "message" fields))
        ++ " stack="
        ++ logfmtValue (boundStack (capture "stack" fields))

-- | Constrains the reported kind to the known values, mapping anything else to @unknown@.
clientErrorKind :: String -> String
clientErrorKind kind
    | kind == "error" || kind == "unhandledrejection" = kind
    | otherwise = "unknown"

-- | Bounds a stack trace to its first 20 frames and 2000 characters.
boundStack :: String -> String
boundStack = take 2000 . unlines . take 20 . lines

-- | A quoted, escaped logfmt value: untrusted client text cannot break the line.
logfmtValue :: String -> String
logfmtValue value = "\"" ++ concatMap escapeLogfmt value ++ "\""
  where
    escapeLogfmt '"' = "\\\""
    escapeLogfmt '\\' = "\\\\"
    escapeLogfmt '\n' = "\\n"
    escapeLogfmt '\r' = "\\r"
    escapeLogfmt '\t' = "\\t"
    escapeLogfmt c = [c]

-- | The request's User-Agent header value, or empty when absent.
requestUserAgent :: Http.RequestHead -> String
requestUserAgent request =
    maybe "" BS.unpack (lookup (Http.normaliseHeaderName (BS.pack "user-agent")) (Http.requestHeaders request))

-- | Renders a connection's peer host as a dotted IPv4 string (as the access log does).
clientPeerHost :: Socket.ConnectionInfo -> String
clientPeerHost conn = case Socket.connPeerHost conn of
    Socket.HostAny -> "0.0.0.0"
    Socket.HostIPv4 a b c d -> show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

{- | Saves a posted Markdown document back to its file in the tree, creating any
missing parent directories. Unlike the flat 'saveDocument', the tree mode does
not apply the raw-HTML guard: the tree holds the user's own trusted documents
(many carry export-metadata HTML comments and occasional markup), so rejecting
raw HTML would block legitimate saves -- the editor preserves it verbatim, and
nothing renders it as live HTML (the trust boundary that guard defends does not
apply to first-party files).
-}
treeSave :: Versioning -> IndexMaintenance -> FilePath -> Router.Handler
treeSave versioning maint root captures request = do
    bodyBytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) formBodyLimit
    let fields = formFields (BS.unpack bodyBytes)
        markdown = normaliseNewlines (capture "markdown" fields)
        path = capture "path" captures
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath ->
            if versioningOn versioning
                then do
                    -- Versioning on: autosave stages a draft; the live page, its sidecar
                    -- metadata, and the link index are untouched until Publish (RFC-0032).
                    Iteratee.liftIO (Draft.writeDraft (draftStagingRoot versioning) path (BS.pack markdown))
                    saveResponse request path markdown
                else do
                    Iteratee.liftIO (Directory.createDirectoryIfMissing True (parentDirectory fsPath))
                    Iteratee.liftIO (writeDocumentText fsPath markdown)
                    Iteratee.liftIO (syncImageTitles root path fields)
                    -- The page's body (and so its outbound links) changed; maintain its index entry.
                    Iteratee.liftIO (onSave maint path)
                    saveResponse request path markdown

{- | The response shared by a draft autosave and a direct (non-versioned) save: an
htmx save-status fragment for the editor, or a redirect back to the edit page for
a no-JavaScript form post.
-}
saveResponse :: Http.RequestHead -> String -> String -> Iteratee.Iter Stream.StreamError Http.Response
saveResponse request path markdown =
    if isHtmxRequest request
        then pure (htmlResponseChunks (saveStatusFragment markdown))
        else pure (seeOtherResponse ("/documents/" ++ path ++ "?edit"))

{- | Publishes the editor's content (RFC-0032): writes it to the live page through
the publish-time path (page write, sidecar image-title sync, link-index update),
records a git commit attributed to the acting author, clears the draft, and exits
to read (view) mode. The submitted @markdown@ (and image fields) are authoritative
-- they equal the resumed draft -- so an unchanged page yields no commit but still
clears the draft.
-}
treePublish :: Versioning -> IndexMaintenance -> FilePath -> Router.Handler
treePublish versioning maint root captures request = do
    bodyBytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) formBodyLimit
    let fields = formFields (BS.unpack bodyBytes)
        markdown = normaliseNewlines (capture "markdown" fields)
        path = capture "path" captures
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            Iteratee.liftIO (Directory.createDirectoryIfMissing True (parentDirectory fsPath))
            Iteratee.liftIO (writeDocumentText fsPath markdown)
            Iteratee.liftIO (syncImageTitles root path fields)
            Iteratee.liftIO (onSave maint path)
            let author = Identity.currentIdentity (versioningIdentity versioning) request
            _ <- Iteratee.liftIO (Git.commitAll root author (publishMessage path markdown))
            Iteratee.liftIO (Draft.deleteDraft (draftStagingRoot versioning) path)
            clientRedirect request ("/documents/" ++ path)

{- | Discards a page's staged draft without publishing (RFC-0032) and returns to
read (view) mode. The path is validated against the tree before the draft is
touched.
-}
treeDiscard :: Versioning -> FilePath -> Router.Handler
treeDiscard versioning root captures request =
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just _ -> do
            Iteratee.liftIO (Draft.deleteDraft (draftStagingRoot versioning) path)
            clientRedirect request ("/documents/" ++ path)
  where
    path = capture "path" captures

-- | The auto-generated commit message for a publish: the page's frontmatter title, falling back to its path.
publishMessage :: String -> String -> String
publishMessage path markdown =
    case frontmatterTitle markdown of
        Just title -> "Publish " ++ title
        Nothing -> "Publish " ++ path

{- | Sends the client to @target@: an @HX-Redirect@ header for an htmx request (so
htmx does a full navigation), or a @303@ for a plain form post. Used to leave edit
mode after publishing or discarding.
-}
clientRedirect :: Http.RequestHead -> String -> Iteratee.Iter Stream.StreamError Http.Response
clientRedirect request target =
    if isHtmxRequest request
        then
            pure
                ( Http.Response
                    Http.okStatus
                    [(Http.normaliseHeaderName (BS.pack "HX-Redirect"), BS.pack target)]
                    (Http.StrictBody BS.empty)
                )
        else pure (seeOtherResponse target)

{- | The revision-history view (RFC-0032): @GET /documents/\<path\>?history@ renders
the page's git revisions (newest first) with a compare form (pick two revisions to
diff) and a per-row roll-back button. An empty history (no repository, or an
untracked page) renders an empty-state page.
-}
treeHistory :: String -> FilePath -> String -> Iteratee.Iter Stream.StreamError Http.Response
treeHistory editorThemeDefault root path = do
    revs <- Iteratee.liftIO (Git.logForPath root path)
    pure (documentResponse (historyPage editorThemeDefault path revs))

{- | The diff view (RFC-0032): @GET /documents/\<path\>?diff&from=\<rev\>&to=\<rev\>@
renders the unified diff of the page between the two revisions with per-line
add\/remove highlighting.
-}
treeDiff :: String -> FilePath -> String -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
treeDiff editorThemeDefault root path request = do
    let fromRev = queryValue "from" request
        toRev = queryValue "to" request
    diff <- Iteratee.liftIO (Git.diffBetween root fromRev toRev path)
    pure (documentResponse (diffPage editorThemeDefault path fromRev toRev diff))

{- | The rollback action (RFC-0032): @POST /documents/\<path\>?rollback@ with a
@rev@ field restores the page's content at that revision, writes it through the
publish-time path, commits it as a new revision (forward-only -- history is never
rewritten), and returns to the read view.
-}
treeRollback :: Versioning -> IndexMaintenance -> FilePath -> Router.Handler
treeRollback versioning maint root captures request = do
    bodyBytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) treeCreateMaxBytes
    let fields = formFields (BS.unpack bodyBytes)
        rev = capture "rev" fields
        path = capture "path" captures
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            content <- Iteratee.liftIO (Git.showFileAtRevision root rev path)
            if BS.null content
                then pure (statusResponse 409 "Conflict" "cannot read that revision\n")
                else do
                    Iteratee.liftIO (BS.writeFile fsPath content)
                    Iteratee.liftIO (onSave maint path)
                    let author = Identity.currentIdentity (versioningIdentity versioning) request
                    _ <- Iteratee.liftIO (Git.commitAll root author ("Roll back " ++ path ++ " to " ++ rev))
                    clientRedirect request ("/documents/" ++ path)

{- | The full-page shell shared by the history and diff views. It reuses the
editor page's theming (the @wa-@ palette classes, the @data-editor-theme@ default,
the theme-bootstrap script, and both stylesheets) so the version pages match the
editor\/reader look (RFC-0032).
-}
versionPageShell :: String -> String -> Html.Html () -> Html.Html ()
versionPageShell themeDefault pageTitle bodyContent =
    Html.html [Html.lang "en", Html.class_ "wa-theme-default wa-palette-default wa-brand-blue", Html.attr "data-editor-theme" (safeEditorTheme themeDefault)] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.rawTrusted editorThemeBootstrapScript
            Html.title [] (Html.text pageTitle)
            Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/webawesome.css\">"
            Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
        Html.body [Html.class_ "markdown-editor-page verso-version-page"] $
            Html.main [] bodyContent

-- | Renders the revision-history page: a back link, a checkbox-per-revision table with a Compare control, and per-row roll-back.
historyPage :: String -> String -> [Git.Revision] -> Html.Html ()
historyPage themeDefault path revs =
    versionPageShell themeDefault ("Revision history: " ++ path) $ do
        Html.el "h1" [] (Html.text "Revision history")
        Html.p [Html.class_ "verso-version-back"] (Html.a [Html.href ("/documents/" ++ path)] (Html.text ("Back to " ++ path)))
        if null revs
            then Html.p [] (Html.text "No revisions yet.")
            else do
                Html.p [Html.class_ "verso-compare"] $
                    Html.el "button" [Html.attr "type" "button", Html.class_ "verso-compare-button", Html.attr "data-path" path, Html.attr "disabled" ""] (Html.text "Compare selected")
                Html.el "table" [Html.class_ "verso-history"] $ do
                    Html.el "thead" [] (Html.el "tr" [] (mapM_ (Html.el "th" [] . Html.text) ["", "When", "Who", "Message", ""]))
                    Html.el "tbody" [] (mapM_ (revisionRow path) revs)
                Html.rawTrusted historyCompareScript

-- | One history-table row: a select checkbox, timestamp, author, subject, and a roll-back form.
revisionRow :: String -> Git.Revision -> Html.Html ()
revisionRow path rev =
    Html.el "tr" [] $ do
        Html.el "td" [] (Html.input [Html.attr "type" "checkbox", Html.class_ "verso-pick", Html.attr "name" "rev", Html.attr "value" (Git.revHash rev)])
        Html.el "td" [] (Html.text (Git.revTimestamp rev))
        Html.el "td" [] (Html.text (Git.revAuthor rev))
        Html.el "td" [] (Html.text (Git.revSubject rev ++ " (" ++ Git.revShort rev ++ ")"))
        Html.el "td" [] $
            Html.el "form" [Html.attr "method" "post", Html.attr "action" ("/documents/" ++ path ++ "?rollback")] $ do
                Html.input [Html.attr "type" "hidden", Html.attr "name" "rev", Html.attr "value" (Git.revHash rev)]
                Html.el "button" [Html.attr "type" "submit", Html.class_ "verso-rollback-button"] (Html.text "Roll back to this")

{- | The history page's client script: limits selection to two revision
checkboxes (disabling the rest once two are picked), enables the Compare button
only when exactly two are selected, and on click navigates to the diff of the two
(older as @from@, newer as @to@, since the list is newest-first).
-}
historyCompareScript :: String
historyCompareScript =
    "<script>(function(){"
        ++ "var boxes=[].slice.call(document.querySelectorAll('.verso-pick'));"
        ++ "var btn=document.querySelector('.verso-compare-button');"
        ++ "function picked(){return boxes.filter(function(b){return b.checked;});}"
        ++ "function update(){var c=picked();boxes.forEach(function(b){b.disabled=(c.length>=2&&!b.checked);});if(btn){btn.disabled=(c.length!==2);}}"
        ++ "boxes.forEach(function(b){b.addEventListener('change',update);});"
        ++ "if(btn){btn.addEventListener('click',function(){var c=picked();if(c.length!==2){return;}"
        ++ "var to=c[0].value,from=c[1].value;var p=btn.getAttribute('data-path');"
        ++ "window.location.href='/documents/'+p+'?diff&from='+encodeURIComponent(from)+'&to='+encodeURIComponent(to);});}"
        ++ "update();"
        ++ "})();</script>"

-- | Renders the diff page: a back link and the unified diff with per-line add\/remove highlighting.
diffPage :: String -> String -> String -> String -> String -> Html.Html ()
diffPage themeDefault path fromRev toRev diff =
    versionPageShell themeDefault ("Diff: " ++ path) $ do
        Html.el "h1" [] (Html.text "Diff")
        Html.p [Html.class_ "verso-version-back"] (Html.a [Html.href ("/documents/" ++ path ++ "?history")] (Html.text "Back to history"))
        Html.p [] (Html.text (shortRev fromRev ++ " to " ++ shortRev toRev))
        if null diff
            then Html.p [] (Html.text "No differences.")
            else Html.el "pre" [Html.class_ "verso-diff"] (mapM_ diffLine (lines diff))
  where
    shortRev = take 12
    diffLine l = Html.el "div" [Html.class_ (diffLineClass l)] (Html.text l)

-- | Classifies a unified-diff line for CSS styling: meta header, hunk header, addition, removal, or context.
diffLineClass :: String -> String
diffLineClass line = case line of
    ('+' : '+' : '+' : _) -> "verso-diff-meta"
    ('-' : '-' : '-' : _) -> "verso-diff-meta"
    ('@' : '@' : _) -> "verso-diff-hunk"
    ('+' : _) -> "verso-diff-add"
    ('-' : _) -> "verso-diff-del"
    _ -> "verso-diff-ctx"

{- | Sync the page's @images.yaml@ @short_title@s to the alt-derived values the
editor sends with a tree save (RFC-0019, ADR-049): @image_count@ indexed
@image_path_<i>@/@image_title_<i>@ form fields. Each update is surgical and
update-only -- an unmatched @local_path@ or an unchanged value writes nothing
(and a save without the fields, e.g. a no-JavaScript post, is a no-op). The count
is capped so a crafted value cannot drive an unbounded loop.
-}
syncImageTitles :: FilePath -> String -> [(String, String)] -> IO ()
syncImageTitles root path fields =
    case DocumentMeta.metaDirectoryFor root path of
        Nothing -> pure ()
        Just metaDir -> mapM_ (applyImageTitle metaDir fields) [0 .. imageCount fields - 1]

-- | Apply one indexed image-title field to the page's @images.yaml@ (no-op when its path is blank).
applyImageTitle :: FilePath -> [(String, String)] -> Int -> IO ()
applyImageTitle metaDir fields index =
    if null localPath
        then pure ()
        else DocumentMeta.updateImageShortTitle metaDir localPath (capture ("image_title_" ++ show index) fields)
  where
    localPath = capture ("image_path_" ++ show index) fields

-- | The number of image-title entries the save carries, parsed from @image_count@ and capped.
imageCount :: [(String, String)] -> Int
imageCount fields = min maxImageTitleEntries (parseNonNegativeInt (capture "image_count" fields))

-- | An upper bound on synced image titles per save, so a crafted @image_count@ cannot loop unbounded.
maxImageTitleEntries :: Int
maxImageTitleEntries = 1000

-- | Parse a non-negative decimal integer, or @0@ for anything else.
parseNonNegativeInt :: String -> Int
parseNonNegativeInt s
    | not (null s) && all Char.isDigit s = foldl (\acc c -> acc * 10 + Char.digitToInt c) 0 s
    | otherwise = 0

-- | Whether a query flag (a key, with or without a value) is present in the request query.
hasQueryFlag :: String -> Http.RequestHead -> Bool
hasQueryFlag name request =
    any (\(key, _) -> key == name) (Http.requestQuery request)

-- | Whether a tree path names a Markdown document.
isMarkdownPath :: String -> Bool
isMarkdownPath path =
    ".md" `List.isSuffixOf` path

-- | The non-empty @/@-separated segments of a tree path (the input to 'Static.resolveStaticPath').
pathSegments :: String -> [String]
pathSegments path =
    filter (not . null) (splitOn '/' path)

-- | The parent directory of a filesystem path (everything up to the last @/@), or @"."@ if none.
parentDirectory :: FilePath -> FilePath
parentDirectory fsPath =
    case break (== '/') (reverse fsPath) of
        (_, '/' : rest) -> reverse rest
        (_, _) -> "."

-- | A @Content-Type@ header with the given media type value.
contentTypeHeader :: String -> Http.Header
contentTypeHeader value =
    (Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack value)

-- | The plain-text @404@ response for a missing or unsafe tree path.
treeNotFound :: Http.Response
treeNotFound =
    Http.Response
        (Http.Status 404 "Not Found")
        [contentTypeHeader "text/plain"]
        (Http.StrictBody (BS.pack "not found\n"))

-- | The flat-mode landing page handler.
index :: Router.Handler
index _ _ =
    pure (documentResponse indexPage)

-- | The flat-mode editor page handler for a document id.
editDocument :: String -> DocumentStore -> Router.Handler
editDocument editorThemeDefault store captures request = do
    let docId = documentId captures
    content <- Iteratee.liftIO (loadDocument store docId)
    pure (documentResponse (editorPage docId (editorMode request) editorThemeDefault (BS.pack content) False True False [] [] "" Nothing))

-- | The flat-mode handler that serves a document's raw Markdown.
showDocument :: DocumentStore -> Router.Handler
showDocument store captures _ = do
    markdown <- Iteratee.liftIO (loadDocument store (documentId captures))
    pure (markdownResponse markdown)

{- | Saves a posted Markdown document, answering both htmx and ordinary form
posts from one route (RFC-0001). An htmx request (the @hx-request@ header is
present) keeps the status-fragment behaviour; an ordinary form post follows
post-redirect-get on success (@303@ back to the edit page) and re-renders the
edit page with the validation message and the submitted Markdown on failure.
-}
saveDocument :: String -> DocumentStore -> Router.Handler
saveDocument editorThemeDefault store captures request = do
    bodyBytes <- Iteratee.readBodyStrict (Stream.StreamParseError Parse.BodyTooLarge) formBodyLimit
    let markdown = markdownFromBody bodyBytes
        docId = documentId captures
    case validateMarkdown markdown of
        Just err
            | isHtmxRequest request -> pure (htmlResponseChunks (validationStatusFragment err))
            | otherwise ->
                pure (documentResponse (editorPage docId Nothing editorThemeDefault (BS.pack markdown) False True False [] [] "" (Just err)))
        Nothing -> do
            Iteratee.liftIO (saveDocumentContent store docId markdown)
            if isHtmxRequest request
                then pure (htmlResponseChunks (saveStatusFragment markdown))
                else pure (seeOtherResponse ("/documents/" ++ docId ++ "/edit"))

-- | The handler's own body bound; the server pipeline also caps the body.
formBodyLimit :: Int
formBodyLimit = 1048576

{- | An HTML response built from the editor's chunk builder (RFC-0013): the body
is the coalesced chunks concatenated into one strict body, avoiding the @String@
round-trip and whole-page pack-copy of the old renderer. Coalescing keeps the
socket-write count low; for pages below the buffer this is a single segment.
-}
htmlResponseChunks :: Html.Html () -> Http.Response
htmlResponseChunks page =
    Http.Response
        Http.okStatus
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/html")]
        (Http.StrictBody (BS.concat (Html.renderChunks page)))

-- | A full-document response: the HTML5 doctype followed by the page.
documentResponse :: Html.Html () -> Http.Response
documentResponse page =
    htmlResponseChunks (Html.rawTrusted "<!doctype html>" >> page)

-- | A @200@ @text/markdown@ response with the given body.
markdownResponse :: String -> Http.Response
markdownResponse body =
    Http.Response
        Http.okStatus
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/markdown")]
        (Http.StrictBody (BS.pack body))

-- | A @303 See Other@ redirect to the given location, with an empty body.
seeOtherResponse :: String -> Http.Response
seeOtherResponse location =
    Http.Response
        (Http.Status 303 "See Other")
        [(Http.normaliseHeaderName (BS.pack "Location"), BS.pack location)]
        (Http.StrictBody (BS.pack ""))

{- | Whether a request came from htmx, identified by the @hx-request@ header
(request header names are normalised to lower case at parse time, RFC-0001).
-}
isHtmxRequest :: Http.RequestHead -> Bool
isHtmxRequest req =
    any (\(key, _) -> key == hxRequestHeader) (Http.requestHeaders req)
  where
    hxRequestHeader = Http.normaliseHeaderName (BS.pack "hx-request")

-- | The first value bound to a capture/field key, or @""@ when absent.
capture :: String -> Router.Captures -> String
capture _ [] = ""
capture name ((key, value) : rest)
    | name == key = value
    | otherwise = capture name rest

-- | The @id@ capture (the flat-mode document id).
documentId :: Router.Captures -> String
documentId =
    capture "id"

-- | Loads a flat-mode document's text from disk, or the seed when the file is absent.
loadFileDocument :: FilePath -> String -> IO String
loadFileDocument root name = do
    let path = documentPath root name
    exists <- Directory.doesFileExist path
    if exists
        then readDocumentText path
        else return seededMarkdown

-- | Saves a flat-mode document's text to its file.
saveFileDocument :: FilePath -> String -> String -> IO ()
saveFileDocument root name =
    writeDocumentText (documentPath root name)

{- | Read a document's bytes as an opaque (UTF-8) string and write them back
verbatim. The document is handled as bytes, never decoded: MicroHs's 'readFile'
decodes UTF-8 to Unicode characters which the @Char8@ HTML builder then truncates
to one byte each, corrupting every multibyte character (and 'writeFile' would
re-encode on save). Reading and writing the raw bytes keeps the file byte-exact
end to end -- the same property the static @?raw@/asset serving already has.
-}
readDocumentText :: FilePath -> IO String
readDocumentText path = fmap BS.unpack (BS.readFile path)

-- | Writes a document's bytes verbatim (the byte-exact counterpart of 'readDocumentText').
writeDocumentText :: FilePath -> String -> IO ()
writeDocumentText path content = BS.writeFile path (BS.pack content)

-- | The filesystem path of a flat-mode document (@root/name.md@).
documentPath :: FilePath -> String -> FilePath
documentPath root name =
    root ++ "/" ++ name ++ ".md"

-- | The first value of a query-string key, or @""@ when absent.
queryValue :: String -> Http.RequestHead -> String
queryValue name request =
    capture name (Http.requestQuery request)

{- | The explicitly requested view mode from @?mode@, or 'Nothing' when absent
so the editor can fall back to a theme's default mode (RFC-0015 presets).
-}
editorMode :: Http.RequestHead -> Maybe String
editorMode request =
    case queryValue "mode" request of
        "source" -> Just "source"
        "split" -> Just "split"
        "visual" -> Just "visual"
        _ -> Nothing

-- | The @markdown@ form field from a request body, newline-normalised.
markdownFromBody :: BS.ByteString -> String
markdownFromBody bytes =
    normaliseNewlines (capture "markdown" (formFields (BS.unpack bytes)))

{- | Canonicalises line endings to @\\n@. A no-JavaScript form post encodes
textarea newlines as @CRLF@ (HTML form submission, RFC-0001), so the document
contract stays line-feed only regardless of submission mode.
-}
normaliseNewlines :: String -> String
normaliseNewlines [] = []
normaliseNewlines ('\r' : '\n' : rest) = '\n' : normaliseNewlines rest
normaliseNewlines ('\r' : rest) = '\n' : normaliseNewlines rest
normaliseNewlines (c : rest) = c : normaliseNewlines rest

-- | Parses an @application/x-www-form-urlencoded@ body into decoded key/value pairs.
formFields :: String -> [(String, String)]
formFields "" = []
formFields body =
    map parseField (splitOn '&' body)

-- | Parses one @key=value@ form field, URL-decoding both sides (empty value when no @=@).
parseField :: String -> (String, String)
parseField field =
    case break (== '=') field of
        (key, '=' : value) -> (Http.decodeFormValue key, Http.decodeFormValue value)
        (key, _) -> (Http.decodeFormValue key, "")

-- | Splits a string on a separator character, keeping empty segments.
splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]

-- | The flat-mode landing page markup.
indexPage :: Html.Html ()
indexPage =
    Html.html [Html.lang "en"] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.title [] "MicroHttp Test App"
        Html.body [] $ do
            Html.main [] $ do
                Html.h1 [] "MicroHttp"
                Html.p [] "The MicroHs HTTP server is running."
                Html.custom "status-card" [Html.attr "data-state" "ok"] "Served by src/Verso/Main.hs"

{- | The visual themes the editor implements (RFC-0015). The page default and
the pre-paint bootstrap validate against this set, so an unknown configured or
stored value falls back to Paper.
-}
knownEditorThemes :: [String]
knownEditorThemes = ["paper", "aurora", "blueprint", "workbench", "studio"]

-- | Validates a configured default theme name, falling back to @paper@.
safeEditorTheme :: String -> String
safeEditorTheme theme
    | theme `elem` knownEditorThemes = theme
    | otherwise = "paper"

{- | A JavaScript array literal of the given strings, e.g. @['a','b']@. The
theme names are simple identifiers, so single-quoting without escaping is safe;
this keeps the bootstrap allowlist derived from 'knownEditorThemes' rather than
duplicated. (The dropdown's parallel list lives in the editor TypeScript.)
-}
jsStringArray :: [String] -> String
jsStringArray items =
    "[" ++ List.intercalate "," (map (\item -> "'" ++ item ++ "'") items) ++ "]"

{- | An inline, pre-paint script that applies the visitor's stored editor
preferences before the body renders, so a saved theme or colour scheme does not
flash the page default. It sets the theme attribute only from a fixed allowlist,
so a tampered stored value cannot inject an attribute payload.
-}
editorThemeBootstrapScript :: String
editorThemeBootstrapScript =
    "<script>(function(){try{"
        ++ "var K="
        ++ jsStringArray knownEditorThemes
        ++ ";var r=document.documentElement;"
        ++ "var t=localStorage.getItem('editor-theme');"
        ++ "if(t&&K.indexOf(t)>=0){r.setAttribute('data-editor-theme',t);}"
        ++ "var s=localStorage.getItem('editor-color-scheme');"
        ++ "if(s==='dark'){r.classList.add('wa-dark');}else if(s==='light'){r.classList.add('wa-light');}"
        ++ "}catch(e){}})();</script>"

{- | The Markdown editor page (RFC-0001). It is a complete, server-rendered form
that works without JavaScript: a @\<textarea name="markdown"\>@ holding the
current document inside the @\<markdown-editor\>@ element, and a no-script submit
button. When scripting is available the element adopts the textarea, participates
in form submission through @ElementInternals@, and htmx autosaves; the textarea
is disabled so it does not double-submit. @maybeError@ re-renders a validation
message after a failed ordinary post.
-}
editorPage :: String -> Maybe String -> String -> BS.ByteString -> Bool -> Bool -> Bool -> [(String, String)] -> [Crumb] -> String -> Maybe String -> Html.Html ()
editorPage docId mode themeDefault content treeMode editable hasDraft attachments breadcrumbs treeSpine maybeError =
    Html.html [Html.lang "en", Html.class_ "wa-theme-default wa-palette-default wa-brand-blue", Html.attr "data-editor-theme" (safeEditorTheme themeDefault)] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.rawTrusted editorThemeBootstrapScript
            Html.title [] "MicroHttp Markdown Editor"
            Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/webawesome.css\">"
            Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
            Html.rawTrusted "<script src=\"https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js\"></script>"
            Html.rawTrusted "<script src=\"/static/editor/markdown-editor.js\"></script>"
        Html.body [Html.class_ "markdown-editor-page"] $
            Html.main [] $
                -- The read view (RFC-0020) has no write path: the element is rendered without the
                -- surrounding autosave form, and marked read-only so the editors and chrome disable editing.
                if editable
                    then Html.form_
                        [ Html.attr "action" ("/documents/" ++ docId)
                        , Html.attr "method" "post"
                        , Html.hxPost ("/documents/" ++ docId)
                        , Html.hxSwap "none"
                        , Html.attr "hx-trigger" "submit, editor:changed delay:2s from:markdown-editor"
                        ]
                        $ do
                            maybe (return ()) validationStatusFragment maybeError
                            editorElement docId mode treeMode editable hasDraft attachments breadcrumbs treeSpine content
                            Html.custom "noscript" [] $
                                Html.button_ [Html.attr "type" "submit"] (Html.text "Save")
                    else editorElement docId mode treeMode editable hasDraft attachments breadcrumbs treeSpine content

{- | The @\<markdown-editor\>@ custom element with its server-set attributes and the
no-script @\<textarea\>@ fallback holding the document. @data-readonly@ is set in the
read view (RFC-0020); the element disables editing and hides the editing chrome.
-}
editorElement :: String -> Maybe String -> Bool -> Bool -> Bool -> [(String, String)] -> [Crumb] -> String -> BS.ByteString -> Html.Html ()
editorElement docId mode treeMode editable hasDraft attachments breadcrumbs treeSpine content =
    Html.custom
        "markdown-editor"
        ( [Html.attr "name" "markdown", Html.attr "data-document" docId]
            ++ maybe [] (\m -> [Html.attr "mode" m]) mode
            ++ [Html.attr "data-document-mode" "tree" | treeMode]
            ++ [Html.attr "data-attachments" (attachmentsJson attachments) | treeMode, not (null attachments)]
            ++ [Html.attr "data-breadcrumbs" (breadcrumbsJson breadcrumbs) | not (null breadcrumbs)]
            ++ [Html.attr "data-tree-spine" treeSpine | treeMode, not (null treeSpine)]
            ++ [Html.attr "data-readonly" "" | not editable]
            -- RFC-0032: marks a page that has an unpublished draft, so the read view can flag it.
            ++ [Html.attr "data-has-draft" "" | hasDraft]
        )
        ( Html.custom
            "textarea"
            [Html.attr "name" "markdown", Html.attr "aria-label" "Markdown source", Html.class_ "markdown-editor__fallback"]
            (Html.bytesText content)
        )

-- | The seed Markdown for a new or missing document.
seededMarkdown :: String
seededMarkdown =
    "# Hello from MicroHttp\n\nEdit this Markdown document."

-- | The htmx save-confirmation status fragment.
saveStatusFragment :: String -> Html.Html ()
saveStatusFragment markdown =
    Html.p [Html.attr "id" "save-status"] $ do
        Html.text "Saved Markdown document: "
        Html.text markdown

-- | The htmx validation-error status fragment.
validationStatusFragment :: String -> Html.Html ()
validationStatusFragment err =
    Html.p [Html.attr "id" "save-status"] $ do
        Html.text "Unsupported Markdown: "
        Html.text err

-- The save-time guard defends the trust boundary only: raw HTML stays rejected
-- (the server never trusts client Markdown to be safe). Block-structure validation
-- was dropped (RFC-0017) -- the editor is the authority on its own open, extensible
-- subset, so keeping a Haskell recogniser in sync would be the cross-language
-- dual-implementation trap ADR-040 rejected for rendering. See ADR-041.
validateMarkdown :: String -> Maybe String
validateMarkdown markdown
    | containsRawHtml markdown = Just "raw HTML is not supported in this spike."
    | otherwise = Nothing

-- | Whether the text contains a @<@ (the raw-HTML guard's crude test).
containsRawHtml :: String -> Bool
containsRawHtml [] = False
containsRawHtml ('<' : _) = True
containsRawHtml (_ : rest) = containsRawHtml rest

-- | Trims leading and trailing whitespace.
trim :: String -> String
trim =
    reverse . trimStart . reverse . trimStart

-- | Drops leading whitespace.
trimStart :: String -> String
trimStart =
    dropWhile Char.isSpace
