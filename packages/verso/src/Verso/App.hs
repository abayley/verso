{-# LANGUAGE OverloadedStrings #-}

module Verso.App (
    NodeKind (..),
    TreeNode (..),
    Structure.Versioning (..),
    Structure.noVersioning,
    appFromConfig,
    appWithDocumentTree,
    appWithDocumentTreeVersioned,
    childrenOf,
    clientErrorRoute,
    searchResultsJson,
    linkedFolderPaths,
    orderTreeNodes,
    Structure.slugify,
    treeChildrenJson,
    treeEntryKind,
    treeRoutes,
) where

import qualified Concordance.Embedding as Embedding
import qualified Concordance.Store as Store
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Form as Form
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Log as Log
import qualified MicroHttp.Middleware as Middleware
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Process as Process
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import qualified MicroHttp.Static as Static
import qualified MicroHttp.Stream as Stream
import qualified MicroHttp.Utf8 as Utf8
import qualified System.Directory as Directory
import qualified System.Exit as Exit
import qualified System.IO as IO
import qualified System.IO.TimeMilli as TimeMilli
import qualified Verso.Attachment as Attachment
import qualified Verso.Config as VConfig
import qualified Verso.DocumentMeta as DocumentMeta
import qualified Verso.Draft as Draft
import qualified Verso.Frontmatter as Frontmatter
import qualified Verso.Git as Git
import qualified Verso.Identity as Identity
import qualified Verso.Json as Json
import qualified Verso.LinkIndexStore as LinkIndexStore
import qualified Verso.Maintenance as Maintenance
import qualified Verso.OperationLog as OperationLog
import qualified Verso.OperationStore as OperationStore
import qualified Verso.SearchIndex as SearchIndex
import qualified Verso.Structure as Structure
import qualified Verso.TrashStore as TrashStore
import qualified Verso.TreeMove as TreeMove
import qualified Verso.TreePath as TreePath
import qualified Verso.View as View

{- | The application composed from configuration (RFC-0011): the access-log
path, document root, and static mounts come from the config, and the parse
limits from the (config-derived) settings. Logging is the outermost middleware.
-}
appFromConfig :: Log.Console -> Server.Settings -> VConfig.VersoConfig -> IO Server.Application
appFromConfig console settings vc = do
    -- Create the writable paths' parent directories up front. Without this a missing parent
    -- (say a fresh checkout with a configured build/ log path) left the server listening but
    -- failing every request on the access-log append -- a confusing failure mode.
    mapM_
        (Directory.createDirectoryIfMissing True . parentDirectory)
        [VConfig.accessLog vc, VConfig.clientErrorLog vc, VConfig.operationLog vc, VConfig.linkIndex vc]
    -- Every startup phase is timed. Startup does seconds of work before it can serve, and
    -- with only a start and an end to go on there was no telling which phase owned a long
    -- gap -- the trash catalogue once held it for 28 seconds and looked like the link
    -- index's doing. Each phase forces its result, so the numbers are the real cost.
    (accessLogger, clientErrorSink) <- Log.timed console "startup: open logger" $ do
        accessLogger <- Log.rotatingFileLogfmtLogger (VConfig.logMaxBytes vc) (VConfig.logKeep vc) (VConfig.accessLog vc)
        clientErrorSink <- Log.rotatingAppender (VConfig.logMaxBytes vc) (VConfig.logKeep vc) (VConfig.clientErrorLog vc)
        pure (accessLogger, clientErrorSink)
    operationStore <-
        Log.timed console "startup: index operation log" (OperationStore.openOperationStore (VConfig.operationLog vc))
    trashStore <-
        Log.timed console "startup: index trash" (TrashStore.openTrashStore (VConfig.trashRoot vc) operationStore)
    -- Open the link index at startup in tree mode (RFC-0029): load the persisted index if
    -- its fingerprint still matches the tree, else build and persist. Move/delete then read
    -- it warm with no per-request walk, and re-export calls POST /index/refresh. When
    -- link_index_enabled is off the index is not opened and move/delete use the byte-scan
    -- fallback (RFC-0032 escape hatch: skip the index entirely).
    maybeIndexStore <-
        if VConfig.linkIndexEnabled vc
            then do
                indexStore <- LinkIndexStore.newLinkIndexStore
                opened <-
                    Log.timed
                        console
                        "startup: build link index"
                        (LinkIndexStore.openLinkIndex (VConfig.documentTreeRoot vc) (VConfig.linkIndex vc) indexStore)
                console (either ("link index FAILED (move/delete degraded until refresh): " ++) (const "link index ready") opened)
                pure (Just indexStore)
            else do
                console "link index disabled (move/delete use the byte-scan fallback)"
                pure Nothing
    -- Ensure the document tree is a git repository when versioning is on (RFC-0032): a one-time
    -- import commit on first run, then reused. A missing git degrades to no versioning, not a crash.
    Monad.when (VConfig.versioningEnabled vc) $ do
        available <- Git.gitAvailable
        if not available
            then console "versioning ON but git not found on PATH (history/publish degraded)"
            else do
                outcome <-
                    Log.timed
                        console
                        "startup: check for git"
                        (Git.ensureRepository (VConfig.documentTreeRoot vc) (importIdentity vc))
                console
                    ( case outcome of
                        Right Git.Initialised -> "git repository initialised (import commit)"
                        Right Git.AlreadyPresent -> "git repository present"
                        Left err -> "versioning ON but git repository setup failed (history/publish degraded): " ++ err
                    )
    -- Serialize structural tree mutations across the server's connection threads (see 'Structure.WriteLock').
    writeLock <- MVar.newMVar ()
    -- Concordance search (RFC-0034): optional; absent shim/model degrades to disabled.
    search <-
        if VConfig.searchEnabled vc
            then Log.timed console "startup: search" (SearchIndex.startSearch (searchConfigFrom console vc))
            else pure Nothing
    pure
        ( Middleware.logRequests
            accessLogger
            ( Middleware.withErrorResponses
                ( Router.serveRoutes
                    (Server.parseLimits settings)
                    (configuredRoutes (Just writeLock) maybeIndexStore search operationStore trashStore vc clientErrorSink)
                )
            )
        )

{- | The route set from configuration: the document tree (a MkDocs-style tree
served and edited in place, with per-page peer @assets/@) plus any static
mounts. The tree is the only serving mode (RFC-0036 retired the flat store);
'VConfig.fromConfig' guarantees a non-empty root.
-}
configuredRoutes :: Structure.WriteLock -> Maybe LinkIndexStore.LinkIndexStore -> Maybe SearchIndex.SearchRuntime -> OperationStore.OperationStore -> TrashStore.TrashStore -> VConfig.VersoConfig -> (String -> IO ()) -> [Router.Route]
configuredRoutes writeLock indexStore search operationStore trashStore vc clientErrorSink =
    clientErrorRoute clientErrorSink
        : treeRoutesWithStores operationStore trashStore writeLock indexStore search (versioningFromConfig vc) (VConfig.documentTreeRoot vc) (VConfig.trashRoot vc) (VConfig.trashRetentionDays vc) (VConfig.linkIndex vc)
        ++ mounts
  where
    -- The editor's own asset directory is a built-in mount (its path is the
    -- `editor_static_dir` config key); `static_mounts` adds any further mounts.
    mounts =
        Static.static "/static/editor" (VConfig.editorStaticDir vc)
            : [Static.static prefix root | (prefix, root) <- VConfig.staticMounts vc]

{- | The search runtime's configuration (RFC-0034): engine paths and the
model profile from config, the page-title logic injected from here (the
frontmatter machinery is the application's).
-}
searchConfigFrom :: Log.Console -> VConfig.VersoConfig -> SearchIndex.SearchConfig
searchConfigFrom console vc =
    SearchIndex.SearchConfig
        { SearchIndex.searchRoot = VConfig.documentTreeRoot vc
        , SearchIndex.searchIndexDir = VConfig.searchIndexDir vc
        , SearchIndex.searchModelId = VConfig.searchModelId vc
        , SearchIndex.searchProfile =
            Embedding.Profile
                { Embedding.profileModelPath = VConfig.searchModel vc
                , Embedding.profilePooling = if VConfig.searchPooling vc == "mean" then 0 else 1
                , Embedding.profileDims = VConfig.searchDims vc
                , Embedding.profileMaxTokens = VConfig.searchMaxTokens vc
                , Embedding.profileThreads = VConfig.searchThreads vc
                , Embedding.profileQueryPrefix = VConfig.searchQueryPrefix vc
                }
        , SearchIndex.searchVocabPath = VConfig.searchVocab vc
        , SearchIndex.searchTitleOf = \path content ->
            Maybe.fromMaybe (humaniseSegment (lastSegment path)) (Frontmatter.title content)
        , SearchIndex.searchLog = console
        }

-- | The tree handlers' versioning context, read from configuration (RFC-0032).
versioningFromConfig :: VConfig.VersoConfig -> Structure.Versioning
versioningFromConfig vc =
    Structure.Versioning
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

{- | Routes that serve and edit a documentation tree on the filesystem. The whole
tree is reachable under @/documents/@; the editor opens at a document's own URL
with @?edit@ (so the page's base path is the file's directory and relative
@assets/...@ links resolve to the real files); a @POST@ writes the @.md@ back;
and every other tree file (images, attachments, raw Markdown) is served
statically and path-safely (every request path is parsed once as a 'TreePath.TreePath'). The document id
is the tree-relative path including the @.md@ extension.
-}
treeRoutes :: Structure.WriteLock -> Maybe LinkIndexStore.LinkIndexStore -> Maybe SearchIndex.SearchRuntime -> Structure.Versioning -> FilePath -> FilePath -> FilePath -> Int -> FilePath -> [Router.Route]
treeRoutes writeLock indexStore search versioning root logPath trashRoot =
    treeRoutesWithStores operationStore (TrashStore.uncachedTrashStore trashRoot logPath) writeLock indexStore search versioning root trashRoot
  where
    operationStore = OperationStore.uncachedOperationStore logPath

-- | The tree routes with warm production stores or uncached adapters for direct route tests.
treeRoutesWithStores :: OperationStore.OperationStore -> TrashStore.TrashStore -> Structure.WriteLock -> Maybe LinkIndexStore.LinkIndexStore -> Maybe SearchIndex.SearchRuntime -> Structure.Versioning -> FilePath -> FilePath -> Int -> FilePath -> [Router.Route]
treeRoutesWithStores operationStore trashStore writeLock indexStore search versioning root trashRoot trashRetentionDays indexPath =
    [ Router.get "/" (redirectTo "/documents/")
    , Router.get "/index.html" (redirectTo "/documents/")
    , Router.get "/search" (treeSearchHandler search)
    , Router.get "/tree/*path" (treeChildrenHandler root)
    , Router.post "/tree/*path" (treePostDispatch structure)
    , Router.get "/trash" (treeTrashListHandler structure trashRetentionDays)
    , Router.get "/trashbin" (treeTrashPageHandler structure trashRetentionDays)
    , Router.post "/trash/*id" (treeRestoreHandler structure)
    , Router.delete "/trash" (treeTrashEmptyHandler structure)
    , Router.delete "/trash/*id" (treeTrashDeleteHandler structure)
    , Router.get "/operations" (treeOperationsHandler operationStore)
    , Router.get "/undo" (treeUndoPageHandler operationStore)
    , Router.post "/undo" (treeUndoHandler structure)
    , Router.post "/index/refresh" (treeRefreshHandler writeLock refresh)
    , Router.put "/documents/*path" (treePutDocument versioning maint root)
    , Router.delete "/tree/*path" (treeDelete structure)
    , Router.put "/drafts/*path" (draftPut versioning root)
    , Router.delete "/drafts/*path" (draftDelete versioning root)
    , Router.post "/documents/*path" (treePost versioning maint root)
    , Router.get "/documents/*path" (treeGet versioning root)
    ]
  where
    -- The server backs page lookups with the warm index (no per-request walk) and
    -- maintains it incrementally after each in-server write; an explicit refresh rebuilds
    -- after a re-export. Without a store (tests, replay) the scan is used and maintenance
    -- is a no-op (RFC-0029).
    findRelevant = maybe TreeMove.scanRelevant TreeMove.indexRelevant indexStore
    maint = Maintenance.combine (maybe Maintenance.none (storeMaintenance root) indexStore) (searchMaintenance search)
    -- The structural operations (RFC-0045): one transaction each over these collaborators.
    structure =
        Structure.Structure
            { Structure.structureRoot = root
            , Structure.structureTrashRoot = trashRoot
            , Structure.structureLock = writeLock
            , Structure.structurePages = findRelevant
            , Structure.structureMaintenance = maint
            , Structure.structureOperations = operationStore
            , Structure.structureTrash = trashStore
            , Structure.structureVersioning = versioning
            , Structure.structureCommit = Structure.commitRevision versioning root
            }
    -- Index refresh (one action over all derived indexes, RFC-0034): rebuild the
    -- link index, then queue the search reconcile sweep (embedding stays async).
    refresh = do
        result <- maybe (pure (Right ())) (LinkIndexStore.refreshLinkIndex root indexPath) indexStore
        maybe (pure ()) SearchIndex.enqueueReconcile search
        pure result

{- | The search re-index hooks (RFC-0034 decision 12): content mutations
enqueue the page; structural mutations queue a reconcile sweep, which also
catches the pages the mutation rewrote (referrers, parent listings --
decision 14's populations). No-ops when search is off.
-}
searchMaintenance :: Maybe SearchIndex.SearchRuntime -> Maintenance.Maintenance
searchMaintenance Nothing _ = pure ()
searchMaintenance (Just runtime) event = case event of
    Maintenance.Moved _ _ -> SearchIndex.enqueueReconcile runtime
    Maintenance.Deleted _ -> SearchIndex.enqueueReconcile runtime
    Maintenance.Created path -> SearchIndex.enqueuePage runtime path
    Maintenance.Restored _ -> SearchIndex.enqueueReconcile runtime
    Maintenance.Saved path -> SearchIndex.enqueuePage runtime path

{- | The maintenance hooks backed by a live store: a move relocates the subtree's keys
and targets in place (pure, no re-read); a delete drops the subtree and re-reads the
parent listing; create/save re-read the written page; restore re-reads the restored
page/subtree and the parent listing. None walk the whole tree.
-}
storeMaintenance :: FilePath -> LinkIndexStore.LinkIndexStore -> Maintenance.Maintenance
storeMaintenance root store event = case event of
    Maintenance.Moved from to -> LinkIndexStore.relocateInIndex from to store
    Maintenance.Deleted path -> LinkIndexStore.removeSubtreeInIndex path store >> reportIndexError (LinkIndexStore.applyChanges root [parentIndexPath path] store)
    Maintenance.Created path -> reportIndexError (LinkIndexStore.applyChanges root [path] store)
    Maintenance.Restored path -> reportIndexError (LinkIndexStore.addSubtreeToIndex root path store) >> reportIndexError (LinkIndexStore.applyChanges root [parentIndexPath path] store)
    Maintenance.Saved path -> reportIndexError (LinkIndexStore.applyChanges root [path] store)
  where
    parentIndexPath p = maybe "index.md" (TreePath.render . TreePath.sectionIndex . TreePath.parent) (TreePath.parse p)

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
treeRefreshHandler :: Structure.WriteLock -> IO (Either String ()) -> Router.Handler
treeRefreshHandler writeLock refresh _ _ = do
    result <- Iteratee.liftIO (Structure.withWriteLock writeLock refresh)
    pure (either (statusResponse 500 "Internal Server Error" . (++ "\n")) (const (jsonResponse (Json.object [("refreshed", Json.bool True)]))) result)

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
treeCreateHandler :: Structure.Structure -> Router.Handler
treeCreateHandler structure captures _ = do
    fields <- formFieldsI treeCreateMaxBytes
    result <- Iteratee.liftIO $
        case (TreePath.parse (capture "path" captures), kindOfWord (capture "kind" fields)) of
            (Nothing, _) -> pure (Left (Structure.Refused "unsafe path"))
            (_, Nothing) -> pure (Left (Structure.Refused "unknown kind"))
            (Just parent, Just kind) -> Structure.create structure parent kind (capture "title" fields)
    pure (either (statusResponse 400 "Bad Request" . (++ "\n") . refusalText) (jsonResponse . createdJson) result)

-- | The kind a create form names, or 'Nothing' for anything but @page@ and @section@.
kindOfWord :: String -> Maybe TreePath.Kind
kindOfWord "page" = Just TreePath.Page
kindOfWord "section" = Just TreePath.Section
kindOfWord _ = Nothing

-- | The created-node JSON: the display name, tree path, kind, and the page path to open for editing.
createdJson :: Structure.Created -> Json.Json
createdJson created =
    Json.object
        [ ("name", Json.string (Structure.createdTitle created))
        , ("path", Json.string (TreePath.render (Structure.createdPath created)))
        , ("kind", Json.string (kindWord (Structure.createdKind created)))
        , ("editPath", Json.string (TreePath.render (Structure.createdEditPath created)))
        ]

-- | @"page"@ or @"section"@ on the wire.
kindWord :: TreePath.Kind -> String
kindWord TreePath.Page = "page"
kindWord TreePath.Section = "section"

{- | Dispatches a @POST /tree/*path@: a section/page move when the @?move@ flag is
present (RFC-0027), otherwise a create (RFC-0026). Delete is a real @DELETE@
on the same path (RFC-0036, 'treeDelete').
-}
treePostDispatch :: Structure.Structure -> Router.Handler
treePostDispatch structure captures request
    | hasQueryFlag "move" request = treeMoveHandler structure (actingAuthor structure request) captures
    | otherwise = treeCreateHandler structure captures request

-- | The author a structural request acts as (RFC-0032), from the configured identity header.
actingAuthor :: Structure.Structure -> Http.RequestHead -> Git.Identity
actingAuthor structure = Identity.currentIdentity (Structure.versioningIdentity (Structure.structureVersioning structure))

{- | The tree delete endpoint (RFC-0036): @DELETE /tree/*path@ moves the page or
section to trash, appends to the operation log, and commits -- the RFC-0027/0028
behaviour behind a real @DELETE@ (it removes the resource at the URL; restore is
the @POST /trash/*id@ controller). Refuses with @409@ and the referrer list when
another page links in.
-}
treeDelete :: Structure.Structure -> Router.Handler
treeDelete structure captures request = Iteratee.liftIO $ do
    result <- case TreePath.parse (capture "path" captures) of
        Nothing -> pure (Left (Structure.Refused "unsafe path"))
        Just target -> Structure.delete structure (actingAuthor structure request) target
    pure (either refusalResponse (jsonResponse . deletedJson) result)

-- | A delete's reply: the deleted path and its trash id.
deletedJson :: Structure.Deleted -> Json.Json
deletedJson deleted =
    Json.object
        [ ("deleted", Json.string (TreePath.render (Structure.deletedPath deleted)))
        , ("trashId", Json.string (TreePath.renderTrashId (Structure.deletedTrashId deleted)))
        ]

{- | The section-move endpoint (RFC-0027): @POST /tree/*path?move@ with form fields
@to@ (destination parent tree path), @slug@ (optional new slug), and @confirm@
(@true@ to apply, otherwise a dry-run preview). Returns the impact plan as JSON, or a
@409@ with the reason on refusal (root, cycle, collision, unsafe path). The body is
read before the operation takes the write lock.
-}
treeMoveHandler :: Structure.Structure -> Git.Identity -> Router.Captures -> Iteratee.Iter Stream.StreamError Http.Response
treeMoveHandler structure author captures = do
    fields <- formFieldsI treeCreateMaxBytes
    let confirm = capture "confirm" fields == "true"
    result <- Iteratee.liftIO $
        case (TreePath.parse (capture "path" captures), TreePath.parse (capture "to" fields)) of
            (Just src, Just destParent) -> Structure.move structure author src destParent (capture "slug" fields) confirm
            _ -> pure (Left (Structure.Refused "unsafe path"))
    pure (either refusalResponse (jsonResponse . TreeMove.movePlanJson) result)

{- | The restore endpoint (RFC-0028): @POST /trash/*id@ moves a trashed entry back to
its origin (re-adding the listing), appends a @restore@ record, and returns the
restored path; a @409@ if the origin is now occupied or the entry is missing.
-}
treeRestoreHandler :: Structure.Structure -> Router.Handler
treeRestoreHandler structure captures request = Iteratee.liftIO $ do
    result <- case TreePath.parseTrashId (capture "id" captures) of
        Nothing -> pure (Left (Structure.Refused "trash entry not found"))
        Just trashId -> Structure.restore structure (actingAuthor structure request) trashId
    pure (either refusalResponse (jsonResponse . restoredJson) result)

-- | A restore's reply: the restored path.
restoredJson :: Structure.Restored -> Json.Json
restoredJson restored = Json.object [("restored", Json.string (TreePath.render (Structure.restoredPath restored)))]

-- | The @409@ for a refused structural operation: the reason as text, or the referrers as JSON for a delete.
refusalResponse :: Structure.Refusal -> Http.Response
refusalResponse (Structure.Refused reason) = statusResponse 409 "Conflict" (reason ++ "\n")
refusalResponse (Structure.StillReferenced referrers) = statusResponse 409 "Conflict" (Json.render (referrersJson referrers))

-- | A refusal as one line of text.
refusalText :: Structure.Refusal -> String
refusalText (Structure.Refused reason) = reason
refusalText (Structure.StillReferenced _) = "still referenced"

-- | A refused-delete body: the referrers as @{"refused":true,"referrers":[{"page","link"}]}@.
referrersJson :: [(String, String)] -> Json.Json
referrersJson referrers =
    Json.object
        [ ("refused", Json.bool True)
        , ("referrers", Json.array (map one referrers))
        ]
  where
    one (page, link) = Json.object [("page", Json.string page), ("link", Json.string link)]

{- | The operations-list endpoint (RFC-0028). An unqualified request returns the
whole log in append order. A @type@ filter with a non-negative @limit@ selects the
newest matching records while preserving append order in the response.
-}
treeOperationsHandler :: OperationStore.OperationStore -> Router.Handler
treeOperationsHandler operationStore _ request = do
    ops <- Iteratee.liftIO (OperationStore.readOperations operationStore)
    let typed = filterOperationsByType (queryValue "type" request) ops
        listed = maybe typed (newestInAppendOrder typed) (nonNegativeQueryInt "limit" request)
    -- The operations list splices the persisted operation-log lines verbatim (RFC-0046 non-goal), so
    -- it is the one JSON response not built from a 'Json.Json' value.
    pure (rawJsonResponse ("[" ++ List.intercalate "," (map OperationLog.renderOperation listed) ++ "]"))

-- | Applies an optional operation-type wire filter; an unknown type matches nothing.
filterOperationsByType :: String -> [OperationLog.Operation] -> [OperationLog.Operation]
filterOperationsByType "" = id
filterOperationsByType "move" = filter ((== OperationLog.OpMove) . OperationLog.opType)
filterOperationsByType "delete" = filter ((== OperationLog.OpDelete) . OperationLog.opType)
filterOperationsByType "restore" = filter ((== OperationLog.OpRestore) . OperationLog.opType)
filterOperationsByType _ = const []

-- | Selects the newest @limit@ records without changing their append order.
newestInAppendOrder :: [a] -> Int -> [a]
newestInAppendOrder operations limit = reverse (take limit (reverse operations))

{- | The undo page (@GET /undo@): a full, newest-first listing of every logged
move with a per-row Undo, for when the recent-moves dropdown is too small.
Complements the dropdown; both invert through @POST /undo@.
-}
treeUndoPageHandler :: OperationStore.OperationStore -> Router.Handler
treeUndoPageHandler operationStore _ request = do
    ops <- Iteratee.liftIO (OperationStore.readOperations operationStore)
    let moves =
            [ (show (OperationLog.opSeq op), from, to, OperationLog.opTs op)
            | op <- reverse ops
            , OperationLog.opType op == OperationLog.OpMove
            , Just from <- [OperationLog.opFrom op]
            , Just to <- [OperationLog.opTo op]
            ]
    -- The page that opened the undo view, so "back" returns there rather than the root.
    pure (documentResponse (View.undoPage (originFromReferer request) moves))

{- | The undo endpoint (RFC-0028): @POST /undo@ applies the inverse of an operation and
appends that inverse as a new record (undo is itself logged, so a further undo is a
redo). A @seq@ form field selects which operation to invert (the undo picker lists
moves and chooses one); without it, the latest operation is inverted. The inverse of a
move is the reverse move; of a delete, a restore; of a restore, a delete. A @409@ when
the log is empty, the seq is unknown, or the inverse cannot be applied (its target is
occupied, missing, or now referenced -- so inverting a non-latest move that has since
moved refuses cleanly rather than corrupting the tree).
-}
treeUndoHandler :: Structure.Structure -> Router.Handler
treeUndoHandler structure _ request = do
    fields <- formFieldsI treeCreateMaxBytes
    result <- Iteratee.liftIO (Structure.undo structure (actingAuthor structure request) (parseSeq (capture "seq" fields)))
    pure (either refusalResponse (jsonResponse . undoneJson) result)

-- | An undo's reply: which inverse applied and where.
undoneJson :: Structure.Undone -> Json.Json
undoneJson (Structure.UndoneMove from to) =
    Json.object [("undo", Json.string "move"), ("from", Json.string (TreePath.render from)), ("to", Json.string (TreePath.render to))]
undoneJson (Structure.UndoneDelete restored) =
    Json.object [("undo", Json.string "delete"), ("restored", Json.string (TreePath.render (Structure.restoredPath restored)))]
undoneJson (Structure.UndoneRestore deleted) =
    Json.object
        [ ("undo", Json.string "restore")
        , ("deleted", Json.string (TreePath.render (Structure.deletedPath deleted)))
        , ("trashId", Json.string (TreePath.renderTrashId (Structure.deletedTrashId deleted)))
        ]

-- | Parses a non-negative @seq@ form value, or 'Nothing' when absent/malformed.
parseSeq :: String -> Maybe Int
parseSeq value = case reads value of
    [(n, "")] -> Just n
    _ -> Nothing

{- | The trash listing endpoint (RFC-0028): @GET /trash@ returns the trash
entries as JSON, newest-first, each tagged with its deletion timestamp -- the
data behind both the recent-deletes dropdown and the trash page.
-}
treeTrashListHandler :: Structure.Structure -> Int -> Router.Handler
treeTrashListHandler structure retentionDays _ request = do
    entries <- Iteratee.liftIO (purgeExpiredTrash structure retentionDays)
    let listed = maybe entries (`take` entries) (nonNegativeQueryInt "limit" request)
    pure (jsonResponse (trashEntriesJson listed))

-- | A non-negative integer query value, or 'Nothing' when absent or malformed.
nonNegativeQueryInt :: String -> Http.RequestHead -> Maybe Int
nonNegativeQueryInt name request =
    case reads (queryValue name request) of
        [(value, "")] | value >= 0 -> Just value
        _ -> Nothing

{- | Permanently removes trash entries older than the retention period, in days
(zero or negative disables the sweep). Runs lazily whenever the trash is listed;
there is no background worker. Ages come from
the operation log's delete timestamps; an entry with no logged timestamp is
never auto-purged. Timestamps compare on their sortable date-time prefix (the
zone suffix is ignored), which is exact to well under a day -- ample here.
-}
purgeExpiredTrash :: Structure.Structure -> Int -> IO [(String, String, String, String)]
purgeExpiredTrash structure retentionDays
    | retentionDays <= 0 = trashEntriesNewestFirst (Structure.structureTrash structure)
    | otherwise = do
        now <- TimeMilli.getTimeMilli
        cutoff <- Log.localTimestampAtMillis (now - retentionDays * 86400000)
        let expired entry = let ts = TrashStore.entryDeletedAt entry in not (null ts) && take 19 ts < take 19 cutoff
        (_, kept) <- Structure.purgeMatching structure expired
        pure (map entryTuple kept)

{- | Permanently deletes one trash entry (@DELETE /trash/\<id\>@, RFC-0028 as
amended): the entry's files are removed for good. Nothing is logged -- the op
log keeps the original delete, and undoing it simply refuses once the entry is
gone. A 404 for an unknown id.
-}
treeTrashDeleteHandler :: Structure.Structure -> Router.Handler
treeTrashDeleteHandler structure captures _ = do
    let trashId = capture "id" captures
    removed <- Iteratee.liftIO (Structure.purge structure trashId)
    pure
        ( if removed
            then jsonResponse (Json.object [("purged", Json.string trashId)])
            else statusResponse 404 "Not Found" "no such trash entry\n"
        )

{- | Empties the trash (@DELETE /trash@): permanently removes every entry.
Answers with the removed count.
-}
treeTrashEmptyHandler :: Structure.Structure -> Router.Handler
treeTrashEmptyHandler structure _ _ = do
    (purged, _) <- Iteratee.liftIO (Structure.purgeMatching structure (const True))
    pure (jsonResponse (Json.object [("emptied", Json.int (length purged))]))

{- | The trash page (@GET /trashbin@): a full, newest-first listing of every
restorable item with a per-row Restore, for when the recent-deletes dropdown is
too small. Complements the dropdown; both restore through @POST /trash/\<id\>@.
-}
treeTrashPageHandler :: Structure.Structure -> Int -> Router.Handler
treeTrashPageHandler structure retentionDays _ request = do
    entries <- Iteratee.liftIO (purgeExpiredTrash structure retentionDays)
    -- The page that opened the trash view, so "back" returns there rather than the root (RFC-0028).
    pure (documentResponse (View.trashPage (originFromReferer request) retentionDays entries))

{- | The originating page for a full-page view's back link (trash, search), taken from the request's
@Referer@ (the page the trash view was opened from): the tree path of its
@\/documents\/\<path\>@, percent-decoded and validated. 'Nothing' when there is no
usable same-tree referer -- a direct visit, a reload, or an off-tree URL -- so the
link falls back to the wiki root.
-}
originFromReferer :: Http.RequestHead -> Maybe String
originFromReferer request = do
    raw <- lookup (Http.normaliseHeaderName (BS.pack "referer")) (Http.requestHeaders request)
    afterDocs <- stringAfter "/documents/" (BS.unpack raw) -- a URL: ASCII on the wire, its escapes UTF-8 bytes
    safeBackLinkOrigin (Utf8.decodeUtf8 (Attachment.percentDecode (takeWhile (\c -> c /= '?' && c /= '#') afterDocs)))

-- | Everything after the first occurrence of @marker@ in @s@, or 'Nothing' when it is absent.
stringAfter :: String -> String -> Maybe String
stringAfter marker = go
  where
    go [] = Nothing
    go s
        | marker `List.isPrefixOf` s = Just (drop (length marker) s)
        | otherwise = go (drop 1 s)

{- | Validates an origin path for a back link: a tree-relative Markdown path
only. Anything with a scheme, a leading slash, or a @..@ segment is rejected (falls
back to the root), so the link can never point off the tree.
-}
safeBackLinkOrigin :: String -> Maybe String
safeBackLinkOrigin origin
    | "/" `List.isPrefixOf` origin = Nothing
    | "://" `List.isInfixOf` origin = Nothing
    | otherwise = case TreePath.parse origin of
        Just page | TreePath.kind page == TreePath.Page -> Just origin
        _ -> Nothing

{- | Trash entries as @(id, originalPath, kind, deletedAt)@, newest-first. A
trash id is its delete's monotonic operation-log seq, so ordering by id
descending is newest-first; the deletion timestamp is joined from the log's
delete records (empty when the log has no matching entry).
-}
trashEntriesNewestFirst :: TrashStore.TrashStore -> IO [(String, String, String, String)]
trashEntriesNewestFirst store = fmap (map entryTuple) (TrashStore.trashEntries store)

-- | A trash entry as the @(id, path, kind, deletedAt)@ tuple the views take.
entryTuple :: TrashStore.TrashEntry -> (String, String, String, String)
entryTuple entry = (TrashStore.entryId entry, TrashStore.entryPath entry, TrashStore.entryKind entry, TrashStore.entryDeletedAt entry)

-- | The enriched trash listing as JSON @[{"id","path","kind","ts"}]@, newest-first.
trashEntriesJson :: [(String, String, String, String)] -> Json.Json
trashEntriesJson entries =
    Json.array (map one entries)
  where
    one (entryId, path, kind, ts) =
        Json.object
            [ ("id", Json.string entryId)
            , ("path", Json.string path)
            , ("kind", Json.string kind)
            , ("ts", Json.string ts)
            ]

-- Replay is an operator action run from the @replay-tool@ CLI (RFC-0028), not a web
-- endpoint, so it is deliberately not surfaced under the routes; the logic lives in
-- 'Verso.TreeMove.replayLog'.

-- | A handler that redirects to a fixed location (a @303 See Other@ to a GET target).
redirectTo :: String -> Router.Handler
redirectTo location _ _ = pure (seeOtherResponse location)

-- | The bare tree-serving application (no middleware), for tests and embedding.
appWithDocumentTree :: FilePath -> Server.Application
appWithDocumentTree root =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        ( Static.static "/static/editor" VConfig.defaultEditorStaticDir
            : treeRoutes Nothing Nothing Nothing Structure.noVersioning root "data/operation_log" "data/trash" 90 "data/link_index"
        )

-- | A tree-mode app with draft/publish versioning on and drafts staged under @draftRoot@ (RFC-0032; tests).
appWithDocumentTreeVersioned :: FilePath -> FilePath -> Server.Application
appWithDocumentTreeVersioned root draftRoot =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        ( Static.static "/static/editor" VConfig.defaultEditorStaticDir
            : treeRoutes Nothing Nothing Nothing (Structure.Versioning True draftRoot Structure.defaultIdentityConfig) root "data/operation_log" "data/trash" 90 "data/link_index"
        )

{- | A GET under the tree: the editor page for @?edit@ on a Markdown file,
otherwise the file served statically (raw Markdown, images, attachments).
-}
treeGet :: Structure.Versioning -> FilePath -> Router.Handler
treeGet versioning root captures request =
    case TreePath.parse (capture "path" captures) of
        Nothing -> pure treeNotFound
        Just parsed -> dispatch (if TreePath.isRoot parsed then TreePath.sectionIndex parsed else parsed)
  where
    -- The tree root (@/documents@ or @/documents/@) resolves to its @index.md@ page.
    dispatch path
        | TreePath.kind path /= TreePath.Page = treeServeFile root path
        | hasQueryFlag "history" request = treeHistory root path
        | hasQueryFlag "diff" request = treeDiff root path request
        | hasQueryFlag "at" request = treeReadAt root path request
        | hasQueryFlag "edit" request = treeEdit versioning root path request
        | hasQueryFlag "raw" request = treeServeFile root path
        | otherwise = treeRead versioning root path request

{- | Renders the editable editor for a tree document, loading its current content
(or a seed if the file is absent, so a missing page can be created by editing).
-}
treeEdit :: Structure.Versioning -> FilePath -> TreePath.TreePath -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
treeEdit versioning root path request = do
    -- Resume a staged draft if one exists (RFC-0032); otherwise the published page, or a seed.
    hasDraft <-
        if Structure.versioningOn versioning
            then Iteratee.liftIO (Draft.hasDraft (Structure.draftStagingRoot versioning) path)
            else pure False
    if hasDraft
        then -- The draft is a file in the staging root: stream it like a page (RFC-0040).
            editFromFile (Draft.draftFsPath (Structure.draftStagingRoot versioning) path) True
        else do
            exists <- Iteratee.liftIO (Directory.doesFileExist fsPath)
            if exists
                then editFromFile fsPath False -- RFC-0040: stream the published page from disk.
                else editSeed -- a new page seeds in memory.
  where
    fsPath = TreePath.resolve root path
    -- The editable shell around the document hole, with the draft flag the read view sets.
    editShell = shellFor path request (Structure.versioningOn versioning) True
    editFromFile file hasDraft = do
        block <- Iteratee.liftIO (Frontmatter.readBlock file)
        chrome <- Iteratee.liftIO (pageChrome root path False block)
        let (before, after) = editShell hasDraft chrome
        Iteratee.liftIO (documentFileResponse before after file)
    editSeed = do
        let content = Utf8.encodeText seededMarkdown
        chrome <- Iteratee.liftIO (pageChrome root path True content)
        let (before, after) = editShell False chrome
        Iteratee.liftIO (documentBytesResponse before after content)

{- | Renders the read-only view for a tree document (the default @GET@, RFC-0020):
the editor shell with editing disabled. A missing page is a @404@ -- reading never
seeds (that stays an @?edit@ affordance).
-}
treeRead :: Structure.Versioning -> FilePath -> TreePath.TreePath -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
treeRead versioning root path request = do
    let fsPath = TreePath.resolve root path
    exists <- Iteratee.liftIO (Directory.doesFileExist fsPath)
    if not exists
        then pure treeNotFound
        else do
            block <- Iteratee.liftIO (Frontmatter.readBlock fsPath)
            chrome <- Iteratee.liftIO (pageChrome root path False block)
            -- RFC-0032: flag an unpublished draft so the read view can mark it next to "Edit".
            hasDraft <-
                if Structure.versioningOn versioning
                    then Iteratee.liftIO (Draft.hasDraft (Structure.draftStagingRoot versioning) path)
                    else pure False
            -- RFC-0040: stream the document from disk between the shell halves; never held whole.
            let (before, after) = shellFor path request (Structure.versioningOn versioning) False hasDraft chrome
            Iteratee.liftIO (documentFileResponse before after fsPath)

-- | Serves a tree file as a sized 'FileBody' with a type from its extension, or a @404@ when absent.
treeServeFile :: FilePath -> TreePath.TreePath -> Iteratee.Iter Stream.StreamError Http.Response
treeServeFile root path = do
    let fsPath = TreePath.resolve root path
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
treePost :: Structure.Versioning -> Maintenance.Maintenance -> FilePath -> Router.Handler
treePost versioning maint root captures request
    | hasQueryFlag "asset" request = treeUpload root captures request
    | hasQueryFlag "image-titles" request = treeImageTitles root captures request
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
    let path = capture "path" captures
        name = Attachment.uploadFilename request
    -- The body never exists as a value: it streams into a temp file beside its final
    -- home and is renamed into place (RFC-0040 phase 3). The refusals still consume the
    -- body, as the strict read did, so nothing is left on the connection.
    case TreePath.parse path of
        Nothing -> notFoundAfterDrain
        Just page
            | not (Attachment.allowedExtension (Attachment.extensionOf name)) ->
                drainBody >> pure (statusResponse 415 "Unsupported Media Type" "attachment type is not allowed\n")
            | otherwise -> do
                let assetsDir = TreePath.resolve root (TreePath.peerAssets page)
                Iteratee.liftIO (Directory.createDirectoryIfMissing True assetsDir)
                tmp <- Iteratee.liftIO (FileSystem.uniqueTempPath assetsDir ".upload")
                _ <- Stream.fileSinkI treeAssetMaxBytes (Stream.StreamParseError Parse.BodyTooLarge) tmp
                placed <- Iteratee.liftIO (storeAsset assetsDir name tmp)
                case placed of
                    Left _ -> pure (statusResponse 500 "Internal Server Error" "could not store the attachment\n")
                    Right stored -> do
                        Iteratee.liftIO (recordAssetMetadata root page stored (Attachment.originalUploadFilename request))
                        pure (jsonResponse (Json.object [("url", Json.string ("assets/" ++ stored))]))

-- | The @404@ for a write whose path is outside the tree, after draining the body so the connection is left clean.
notFoundAfterDrain :: Iteratee.Iter Stream.StreamError Http.Response
notFoundAfterDrain = drainBody >> pure treeNotFound

-- | Consumes and discards the rest of the request body in constant space.
drainBody :: Iteratee.Iter Stream.StreamError ()
drainBody = Iteratee.byteSinkI (\_ -> pure (Right ()))

{- | Record a freshly stored asset in the page's sidecar metadata (ADR-0049): an
inline image in @images.yaml@ (with the original filename as its initial
@short_title@), anything else in @attachments.yaml@. Classification reuses the
attachment store's @inlineImageExtension@.
-}
recordAssetMetadata :: FilePath -> TreePath.TreePath -> String -> String -> IO ()
recordAssetMetadata root page stored originalName
    | Attachment.inlineImageExtension extension = DocumentMeta.appendImage metaDir localPath originalName
    | otherwise = DocumentMeta.appendAttachment metaDir (DocumentMeta.AttachmentEntry originalName localPath extension)
  where
    metaDir = DocumentMeta.metaDirectoryFor root page
    localPath = "assets/" ++ stored
    extension = Attachment.extensionOf stored

-- | The page's recorded attachments as @(name, local_path)@ pairs for the metadata panel, or @[]@.
loadPageAttachments :: FilePath -> TreePath.TreePath -> IO [(String, String)]
loadPageAttachments root page =
    DocumentMeta.readAttachmentEntries (DocumentMeta.metaDirectoryFor root page)

{- | Places an uploaded temp file in the assets folder under a meaningful name,
returning the name actually used. An identical file already present is reused
(dedup; the temp file is removed); a name taken by different content is suffixed
(@diagram.png@ -> @diagram-2.png@ -> ...). The comparison is streamed, size first,
so neither file is read whole (RFC-0040 phase 3).
-}
storeAsset :: FilePath -> String -> FilePath -> IO (Either String String)
storeAsset assetsDir name tmp =
    tryCandidate (candidateNames name)
  where
    tryCandidate [] = place name
    tryCandidate (candidate : rest) = do
        let target = assetsDir ++ "/" ++ candidate
        exists <- Directory.doesFileExist target
        if not exists
            then place candidate
            else do
                same <- Stream.filesEqual tmp target
                case same of
                    Right True -> do
                        _ <- FileSystem.removeFilePath tmp
                        pure (Right candidate)
                    _ -> tryCandidate rest
    -- A rename that fails is an expected outcome (the folder vanished, a permission
    -- changed): reported, with the temp removed so nothing is left beside the assets.
    place candidate = do
        moved <- FileSystem.renamePath tmp (assetsDir ++ "/" ++ candidate)
        case moved of
            Left e -> do
                _ <- FileSystem.removeFilePath tmp
                pure (Left ("cannot place uploaded asset: " ++ show e))
            Right () -> pure (Right candidate)

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

{- | The folder rel-paths whose @index.md@ pages link in a document's breadcrumb trail, root-first and
excluding the current page (the trail's final, unlinked crumb). A folder index page contributes its folder as
the current crumb, so it is not also linked: @"a/b/page.md"@ links @["", "a", "a/b"]@; @"a/index.md"@ links
@["", "a"]@; @"a/page.md"@ links @["", "a"]@; the root @"index.md"@ links @[]@ (it is the current page).
-}
linkedFolderPaths :: String -> [String]
linkedFolderPaths path =
    case TreePath.parse path of
        Nothing -> []
        Just page -> map TreePath.render (properAncestors (if TreePath.name page == "index.md" then TreePath.parent page else page))
  where
    properAncestors node
        | TreePath.isRoot node = []
        | otherwise = properAncestors (TreePath.parent node) ++ [TreePath.parent node]

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
breadcrumbsFor :: FilePath -> TreePath.TreePath -> BS.ByteString -> IO [View.Crumb]
breadcrumbsFor root page content = do
    links <- mapM folderCrumb (Maybe.mapMaybe TreePath.parse (linkedFolderPaths (TreePath.render page)))
    block <- Frontmatter.slice content
    let currentLabel = Maybe.fromMaybe (humaniseSegment (TreePath.name page)) (Frontmatter.titleOf block)
    pure (links ++ [View.Crumb currentLabel Nothing])
  where
    folderCrumb folder = do
        name <- readIndexTitle root folder
        pure (View.Crumb (Maybe.fromMaybe (folderFallback folder) name) (Just (folderHref (TreePath.render folder))))
    folderFallback folder
        | TreePath.isRoot folder = "Cello"
        | otherwise = humaniseSegment (TreePath.name folder)

-- | The last @/@-separated segment of a path (the path itself when it has none).
lastSegment :: String -> String
lastSegment p = maybe p TreePath.name (TreePath.parse p)

-- | A fallback label from a path segment: hyphens and underscores to spaces, each word capitalised.
humaniseSegment :: String -> String
humaniseSegment = unwords . map capitalise . words . map spacer . dropExtension
  where
    spacer c = if c == '-' || c == '_' then ' ' else c
    capitalise [] = []
    capitalise (c : cs) = Char.toUpper c : cs
    dropExtension s = if ".md" `List.isSuffixOf` s then take (length s - 3) s else s

-- | Reads a folder's @index.md@ frontmatter title, or Nothing when the file is absent or untitled.
readIndexTitle :: FilePath -> TreePath.TreePath -> IO (Maybe String)
readIndexTitle root folder = readTitle (TreePath.resolve root (TreePath.sectionIndex folder))

{- | A document's frontmatter title read from disk, touching only the leading block; Nothing
when the file is absent or untitled, decoded from the file's UTF-8 (RFC-0043).
-}
readTitle :: FilePath -> IO (Maybe String)
readTitle fsPath = fmap Frontmatter.titleOf (Frontmatter.readBlock fsPath)

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
and a folder's own @index.md@ (folded into its section, ADR-0058/ADR-0059, not shown
as a child).
-}
treeEntryKind :: String -> Bool -> Maybe NodeKind
treeEntryKind name isDir
    | isHidden = Nothing
    | isDir = Just Section
    | name == "index.md" = Nothing
    | ".md" `List.isSuffixOf` name = Just Page
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
treeChildrenJson :: [TreeNode] -> Json.Json
treeChildrenJson nodes = Json.array (map nodeObject nodes)
  where
    nodeObject n =
        Json.object
            [ ("name", Json.string (nodeName n))
            , ("path", Json.string (nodePath n))
            , ("kind", Json.string (kindString (nodeKind n)))
            , ("hasChildren", Json.bool (nodeHasChildren n))
            ]
    kindString Section = "section"
    kindString Page = "page"

{- | The immediate navigation-tree children of a folder (its tree-relative path,
empty for the root), read live from the filesystem and ordered for display
(RFC-0026, ADR-0059). Returns @[]@ for an unsafe path or a missing directory.
-}
childrenOf :: FilePath -> String -> IO [TreeNode]
childrenOf root parentRel =
    case TreePath.parse parentRel of
        Nothing -> pure []
        Just dir -> do
            let dirFs = TreePath.resolve root dir
            isDir <- Directory.doesDirectoryExist dirFs
            if not isDir
                then pure []
                else do
                    names <- Directory.listDirectory dirFs
                    nodes <- mapM (childNode root dir) names
                    pure (orderTreeNodes (Maybe.catMaybes nodes))

-- | Builds a navigation-tree node for one directory entry, or 'Nothing' when it is hidden (or not a safe name).
childNode :: FilePath -> TreePath.TreePath -> String -> IO (Maybe TreeNode)
childNode root dir name =
    case TreePath.child dir name of
        Nothing -> pure Nothing
        Just child -> do
            let entryFs = TreePath.resolve root child
            isDir <- Directory.doesDirectoryExist entryFs
            case treeEntryKind name isDir of
                Nothing -> pure Nothing
                Just Section -> do
                    label <- sectionLabel root child
                    hasKids <- dirHasVisibleChildren entryFs
                    pure (Just (TreeNode label (TreePath.render child) Section hasKids))
                Just Page -> do
                    label <- pageLabel root child
                    pure (Just (TreeNode label (TreePath.render child) Page False))

-- | A section's label: its @index.md@ frontmatter @name@, or a humanised directory segment.
sectionLabel :: FilePath -> TreePath.TreePath -> IO String
sectionLabel root section = do
    title <- readIndexTitle root section
    pure (Maybe.fromMaybe (humaniseSegment (TreePath.name section)) title)

-- | A page's label: its frontmatter @name@, or a humanised filename.
pageLabel :: FilePath -> TreePath.TreePath -> IO String
pageLabel root page = do
    let fsPath = TreePath.resolve root page
    exists <- Directory.doesFileExist fsPath
    if not exists
        then pure fallback
        else do
            title <- readTitle fsPath
            pure (Maybe.fromMaybe fallback title)
  where
    fallback = humaniseSegment (TreePath.name page)

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
treeSpineFor :: FilePath -> TreePath.TreePath -> IO String
treeSpineFor root page = do
    entries <- mapM folderEntry spineFolders
    pure (Json.render (Json.array entries))
  where
    spineFolders = case linkedFolderPaths (TreePath.render page) of
        [] -> [""]
        fps -> fps
    folderEntry fp = do
        nodes <- childrenOf root fp
        pure (Json.object [("path", Json.string fp), ("children", treeChildrenJson nodes)])

-- | A @200@ JSON response with the given body.
jsonResponse :: Json.Json -> Http.Response
jsonResponse value = rawJsonResponse (Json.render value)

-- | A JSON response from an already-serialised body, for the operations list (see 'treeOperationsHandler').
rawJsonResponse :: String -> Http.Response
rawJsonResponse body =
    Http.Response Http.okStatus [contentTypeHeader "application/json"] (Http.StrictBody (Utf8.encodeText body))

-- | A plain-text response with the given status code, reason, and body.
statusResponse :: Int -> String -> String -> Http.Response
statusResponse code reason body =
    Http.Response (Http.Status code reason) [contentTypeHeader "text/plain"] (Http.StrictBody (Utf8.encodeText body))

-- | The maximum accepted client-error report size in bytes (RFC-0023).
clientErrorMaxBytes :: Int
clientErrorMaxBytes = 8192

{- | The client-error telemetry endpoint (RFC-0023, ADR-0052): a fire-and-forget
@POST /client-errors@ that records one bounded, escaped logfmt line via the given
sink (the rotating client-error log) and returns @204@. A deliberate, write-only
exception to the store-and-serve server (ADR-0019); the report carries no document
content and no user identity.
-}
clientErrorRoute :: (String -> IO ()) -> Router.Route
clientErrorRoute sink = Router.post "/client-errors" (clientErrorHandler sink)

-- | Records one bounded client-error report via the sink and answers @204@.
clientErrorHandler :: (String -> IO ()) -> Router.Handler
clientErrorHandler sink _ request = do
    fields <- formFieldsI clientErrorMaxBytes
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
    maybe "" Utf8.decodeBytes (lookup (Http.normaliseHeaderName (BS.pack "user-agent")) (Http.requestHeaders request))

-- | Renders a connection's peer host as a dotted IPv4 string (as the access log does).
clientPeerHost :: Socket.ConnectionInfo -> String
clientPeerHost conn = case Socket.connPeerHost conn of
    Socket.HostAny -> "0.0.0.0"
    Socket.HostIPv4 a b c d -> show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

{- | The draft resource's @PUT@ (RFC-0036): stages the raw request body as the
page's draft, verbatim (autosave). Idempotent -- re-sending the same bytes
re-stages the same draft -- so a debounced client can retry safely. The path is
validated against the tree exactly as a page save is; without versioning there
is no draft resource, so the route answers 404.
-}
draftPut :: Structure.Versioning -> FilePath -> Router.Handler
draftPut versioning root captures _ = do
    let path = capture "path" captures
    -- The body streams straight into the staging file (RFC-0040); the refusals
    -- still consume it, so nothing is left on the connection.
    if not (Structure.versioningOn versioning)
        then notFoundAfterDrain
        else case TreePath.parse path of
            Nothing -> notFoundAfterDrain
            Just page -> do
                staged <- sinkBodyToFile formBodyLimit (Draft.draftFsPath (Structure.draftStagingRoot versioning) page)
                pure (either (const saveFailed) (const noContentResponse) staged)

{- | The draft resource's @DELETE@ (RFC-0036): discards the page's staged draft
without publishing. Idempotent -- deleting an absent draft is still a @204@.
-}
draftDelete :: Structure.Versioning -> FilePath -> Router.Handler
draftDelete versioning root captures _ = do
    let path = capture "path" captures
    if not (Structure.versioningOn versioning)
        then pure treeNotFound
        else case TreePath.parse path of
            Nothing -> pure treeNotFound
            Just page -> do
                Iteratee.liftIO (Draft.deleteDraft (Structure.draftStagingRoot versioning) page)
                pure noContentResponse

-- | The bodyless @204 No Content@ response for a completed state transfer.
noContentResponse :: Http.Response
noContentResponse =
    Http.Response (Http.Status 204 "No Content") [] (Http.StrictBody BS.empty)

{- | Saves a posted Markdown document back to its file in the tree, creating any
missing parent directories. Unlike the flat 'saveDocument', the tree mode does
not apply the raw-HTML guard: the tree holds the user's own trusted documents
(many carry export-metadata HTML comments and occasional markup), so rejecting
raw HTML would block legitimate saves -- the editor preserves it verbatim, and
nothing renders it as live HTML (the trust boundary that guard defends does not
apply to first-party files).
-}
treeSave :: Structure.Versioning -> Maintenance.Maintenance -> FilePath -> Router.Handler
treeSave versioning maint root captures _request = do
    let path = capture "path" captures
    case TreePath.parse path of
        Nothing -> notFoundAfterDrain
        Just page -> do
            -- Versioning on: autosave stages a draft; the live page, its sidecar
            -- metadata, and the link index are untouched until Publish (RFC-0032).
            let target = if Structure.versioningOn versioning then Draft.draftFsPath (Structure.draftStagingRoot versioning) page else TreePath.resolve root page
            -- RFC-0042: the form streams through the part consumer. The document field
            -- is decoded and newline-normalised on its way into a temp beside the target
            -- and renamed into place; the other fields are collected under small caps.
            -- The document never exists as a value, and the temp is removed on failure.
            placed <- sinkToFile (formSaveSink formBodyLimit) target
            case placed of
                Left _ -> pure saveFailed
                Right _ -> do
                    -- The page's body (and so its outbound links) changed; maintain its index entry.
                    Monad.unless (Structure.versioningOn versioning) (Iteratee.liftIO (maint (Maintenance.Saved path)))
                    saveResponse path

{- | The save form's part consumer, writing into @tmp@: the @markdown@ field is
percent-decoded and newline-normalised block by block into a capped file sink;
every other field is collected as a small value. The temp is created empty first,
so a form with no @markdown@ field saves an empty page, as the whole-body parser
did. A form with two @markdown@ fields saves the last (each opens the temp
afresh), where the whole-body parser took the first; the browser form has one.
The routing is decided from the field name alone, so the form puts any control
field before the @\<textarea\>@ ('View.editorShell').
-}
formSaveSink :: Int -> FilePath -> Iteratee.Iter Stream.StreamError (Form.FormResult Int)
formSaveSink cap tmp = do
    Iteratee.liftIO (BS.writeFile tmp BS.empty)
    Form.formI saveFormLimits tooLarge route
  where
    tooLarge = Stream.StreamParseError Parse.BodyTooLarge
    route name
        | name == BS.pack "markdown" = Form.SinkPart (Form.decodeFormValueI (Form.normaliseNewlinesI (Stream.fileSinkI cap tooLarge tmp)))
        | otherwise = Form.CollectField

{- | The caps on the save form's collected fields: it carries identifiers beside
the document, so a field is small and there are few of them.
-}
saveFormLimits :: Form.FormLimits
saveFormLimits = Form.FormLimits{Form.maxFieldBytes = treeCreateMaxBytes, Form.maxCollectedBytes = 65536, Form.maxFields = 64}

{- | The form-floor save response: post-redirect-get back to the edit page. (The
editor's own saves are fetch PUTs answered with 204, RFC-0036.)
-}
saveResponse :: String -> Iteratee.Iter Stream.StreamError Http.Response
saveResponse path =
    pure (seeOtherResponse ("/documents/" ++ path ++ "?edit"))

{- | The page resource's @PUT@ (RFC-0036): replaces the live page with the raw
request body, stored verbatim (byte-exact, ADR-0038 -- no urlencoding, so
nothing decodes on this hot path), and maintains the page's index entry. With
versioning on this is Publish (RFC-0032): the write is committed, attributed
to the acting author, and the page's staged draft cleared. Idempotent: an
unchanged body yields no new commit (git sees no diff) but still clears the
draft.
-}
treePutDocument :: Structure.Versioning -> Maintenance.Maintenance -> FilePath -> Router.Handler
treePutDocument versioning maint root captures request = do
    let path = capture "path" captures
    case TreePath.parse path of
        Nothing -> notFoundAfterDrain
        Just page -> do
            let fsPath = TreePath.resolve root page
            -- The body streams into a temp beside the page and is renamed into place
            -- (RFC-0040): the document never exists as a value, and a crash mid-write
            -- leaves the previous page intact.
            written <- sinkBodyToFile formBodyLimit fsPath
            case written of
                Left _ -> pure saveFailed
                Right _ -> do
                    Iteratee.liftIO (maint (Maintenance.Saved path))
                    Monad.when (Structure.versioningOn versioning) $ do
                        let author = Identity.currentIdentity (Structure.versioningIdentity versioning) request
                        message <- Iteratee.liftIO (publishMessage path fsPath)
                        committed <- Iteratee.liftIO (Git.commitPaths root author message [path])
                        Iteratee.liftIO (reportPublishCommit committed)
                        Iteratee.liftIO (Draft.deleteDraft (Structure.draftStagingRoot versioning) page)
                    pure noContentResponse

{- | Logs a failed publish commit to stderr; a successful or empty commit is silent. The page bytes are
already saved on disk, so a publish still answers 204, but the commit failure is not swallowed
(matching 'Structure.commitRevision').
-}
reportPublishCommit :: Git.CommitResult -> IO ()
reportPublishCommit (Git.CommitFailed err) = IO.hPutStrLn IO.stderr ("git commit (publish) failed: " ++ err)
reportPublishCommit _ = pure ()

-- | The @500@ for a save whose body arrived but could not be placed as the page.
saveFailed :: Http.Response
saveFailed = statusResponse 500 "Internal Server Error" "could not store the page\n"

{- | Sinks the request body into @target@ (RFC-0040): streamed into a temp file
beside it, then renamed into place, so the body never exists as a value and the
target is replaced atomically. An over-cap body fails the stream having removed
the partial temp ('Stream.fileSinkI'); a rename that fails removes the temp and is
reported as the expected outcome it is. The temp is a dotfile the tree walks skip.
-}
sinkBodyToFile :: Int -> FilePath -> Iteratee.Iter Stream.StreamError (Either String Int)
sinkBodyToFile limit = sinkToFile (Stream.fileSinkI limit (Stream.StreamParseError Parse.BodyTooLarge))

{- | Runs a consumer that writes into a temp file reserved beside @target@, then
renames the temp into place (RFC-0040, RFC-0042). The consumer is built for the
temp path so it can be a plain file sink or a form whose document field sinks
there. A consumer or stream failure removes the temp and propagates; a rename
that fails removes it and is reported as the expected outcome it is.
-}
sinkToFile :: (FilePath -> Iteratee.Iter Stream.StreamError a) -> FilePath -> Iteratee.Iter Stream.StreamError (Either String a)
sinkToFile consumerFor target = do
    let dir = parentDirectory target
    Iteratee.liftIO (Directory.createDirectoryIfMissing True dir)
    tmp <- Iteratee.liftIO (FileSystem.uniqueTempPath dir ".save")
    let discard = Monad.void (FileSystem.removeFilePath tmp)
    result <- Iteratee.onFailure discard (consumerFor tmp)
    moved <- Iteratee.liftIO (FileSystem.renamePath tmp target)
    case moved of
        Left e -> do
            Iteratee.liftIO discard
            pure (Left ("cannot place the page: " ++ show e))
        Right () -> pure (Right result)

{- | The image-title sync controller (RFC-0036): @POST /documents/*path?image-titles@
with the indexed @image_count@/@image_path_<i>@/@image_title_<i>@ form fields
(RFC-0019, ADR-0049). Split out of the save payload so the page body travels as
raw bytes; the editor calls this after a publish, only when the page has
page-relative images. Update-only and idempotent.
-}
treeImageTitles :: FilePath -> Router.Handler
treeImageTitles root captures _request = do
    -- The body carries indexed paths and short titles, never a document, so it is
    -- capped well below 'formBodyLimit': the fields are widened to Strings and a
    -- document-sized String is the cost RFC-0040 removed from every request path.
    fields <- formFieldsI imageTitlesBodyLimit
    case TreePath.parse (capture "path" captures) of
        Nothing -> pure treeNotFound
        Just page -> do
            Iteratee.liftIO (syncImageTitles root page fields)
            pure noContentResponse

{- | The most bytes an image-titles post may carry: a handful of indexed path and
title fields per image, so 64KB covers hundreds of images.
-}
imageTitlesBodyLimit :: Int
imageTitlesBodyLimit = 65536

{- | The auto-generated commit message for a publish: the page's frontmatter
title, falling back to its path. Only the leading frontmatter block is read from
the written page (never the body): MicroHs's 'BS.unpack' builds the whole list
eagerly, so unpacking the document would widen it to a String (RFC-0040).
-}
publishMessage :: String -> FilePath -> IO String
publishMessage path fsPath = do
    block <- Frontmatter.readBlock fsPath
    pure $ case Frontmatter.titleOf block of
        Just title -> "Publish " ++ title
        Nothing -> "Publish " ++ path

{- | The revision-history view (RFC-0032): @GET /documents/\<path\>?history@ renders
the page's git revisions (newest first) with a compare form (pick two revisions to
diff) and a per-row roll-back button. An empty history (no repository, or an
untracked page) renders an empty-state page.
-}
treeHistory :: FilePath -> TreePath.TreePath -> Iteratee.Iter Stream.StreamError Http.Response
treeHistory root page = do
    let path = TreePath.render page
    revs <- Iteratee.liftIO (Git.logForPath root path)
    title <- Iteratee.liftIO (treePageTitle root page)
    pure (documentResponse (View.historyPage title path revs))

-- | A tree page's display title read from disk (fallback: humanised filename).
treePageTitle :: FilePath -> TreePath.TreePath -> IO String
treePageTitle root page = do
    block <- Frontmatter.readBlock (TreePath.resolve root page)
    documentPageTitle False (TreePath.render page) block

{- | The diff view (RFC-0032): @GET /documents/\<path\>?diff&from=\<rev\>&to=\<rev\>@
renders a side-by-side diff of the page between the two revisions. With the
@pane@ flag it returns just the diff fragment (for the history page's diff pane);
otherwise a full standalone page.
-}
treeDiff :: FilePath -> TreePath.TreePath -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
treeDiff root page request = do
    let path = TreePath.render page
        fromRev = queryValue "from" request
        toRev = queryValue "to" request
        pane = hasQueryFlag "pane" request
    -- RFC-0040 phase 5/9: the diff is captured to a file and streamed through the side-by-side transform
    -- a line at a time, so neither the whole diff nor the rendered table is held in the heap.
    Iteratee.liftIO $ Git.withDiffCapture root fromRev toRev path $ \cap -> do
        empty <- captureEmpty cap
        if empty
            then do
                -- No differences (or the command failed): a small whole response, no streaming.
                Process.Finished
                    <$> if pane
                        then pure (htmlResponseChunks (View.diffBody fromRev toRev ""))
                        else do
                            title <- treePageTitle root page
                            pure (documentResponse (View.diffPage title path fromRev toRev ""))
            else do
                -- The stderr capture is not needed; the stdout capture becomes the body's, removed when the body finishes.
                Monad.void (FileSystem.removeFilePath (Process.captureErr cap))
                (before, after) <-
                    if pane
                        then pure (View.diffPaneHalves fromRev toRev)
                        else do
                            title <- treePageTitle root page
                            let (b, a) = View.diffPageHalves title path fromRev toRev
                            pure (BS.pack "<!doctype html>" `BS.append` b, a)
                pure (Process.HandedOff (Http.Response Http.okStatus documentHtmlHeaders (Http.StreamBody (diffStreamBody before (Process.captureOut cap) after))))

{- | Streams a diff response body (RFC-0040): the chrome before the rows, then the
capture file's lines folded through the side-by-side transform into HTML row bytes,
then the chrome after, and the capture removed when the body finishes. Only one line
and the current change block are held at a time. A read failure mid-body leaves a
truncated body (the head is already sent), as any streamed response can.
-}
diffStreamBody :: BS.ByteString -> FilePath -> BS.ByteString -> Iteratee.Enumerator Stream.StreamError ()
diffStreamBody before capturePath after sink0 = do
    sink1 <- Iteratee.feedChunk before sink0
    -- the body owns the capture: the temp fold removes it when the fold returns, however it ends
    folded <- Stream.foldTempFileLines lineStep (sink1, View.diffScanInit) capturePath
    case folded of
        Left _ -> pure sink1
        Right (sink2, scanState) -> do
            sink3 <- Iteratee.feedChunk (View.diffScanFlush scanState) sink2
            Iteratee.feedChunk after sink3
  where
    lineStep (sink, scanState) line = do
        let (scanState', rowBytes) = View.diffScanStep scanState line
        sink' <- Iteratee.feedChunk rowBytes sink
        pure (sink', scanState')

{- | View a page as it was at a revision (RFC-0032): @GET /documents/\<path\>?at=\<rev\>@
renders the read-only editor over the page's content at that revision. Assets
referenced by the old content resolve against the /current/ tree, so an asset
removed since then will be missing -- an accepted limitation. A revision where the
page did not exist is a @404@.
-}
treeReadAt :: FilePath -> TreePath.TreePath -> Http.RequestHead -> Iteratee.Iter Stream.StreamError Http.Response
treeReadAt root page request = do
    let path = TreePath.render page
        rev = queryValue "at" request
    -- RFC-0040 phase 5: the revision is captured to a file, streamed as the document, and removed
    -- when the body finishes; it never enters the heap.
    Iteratee.liftIO $ Git.withFileAtRevisionCapture root rev path $ \cap -> do
        -- git show exits non-zero, or yields nothing, when the path did not exist at that revision.
        empty <- captureEmpty cap
        if empty
            then pure (Process.Finished treeNotFound)
            else do
                -- The stderr capture is not needed; the stdout capture becomes the temp-file body's,
                -- removed when the body finishes or the consumer stops. A crash before that point
                -- is covered by the handoff bracket, which removes both files and rethrows.
                Monad.void (FileSystem.removeFilePath (Process.captureErr cap))
                let out = Process.captureOut cap
                block <- Frontmatter.readBlock out
                chrome <- pageChrome root page False block
                let (before, after) = shellFor page request False False False chrome
                Process.HandedOff <$> documentTempFileResponse before after out

{- | The rollback action (RFC-0032): @POST /documents/\<path\>?rollback@ with a
@rev@ field restores the page's content at that revision, writes it through the
publish-time path, commits it as a new revision (forward-only -- history is never
rewritten), and returns to the read view.
-}
treeRollback :: Structure.Versioning -> Maintenance.Maintenance -> FilePath -> Router.Handler
treeRollback versioning maint root captures request = do
    fields <- formFieldsI treeCreateMaxBytes
    let rev = capture "rev" fields
    case TreePath.parse (capture "path" captures) of
        Nothing -> pure treeNotFound
        Just page -> do
            let path = TreePath.render page
                fsPath = TreePath.resolve root page
            -- RFC-0040 phase 5: the revision is captured to a file and streamed into place, never
            -- routed through the heap.
            -- the capture lives only as long as the copy: withCapture removes it however this exits
            copied <- Iteratee.liftIO $ Git.withFileAtRevisionCapture root rev path $ \cap -> do
                empty <- captureEmpty cap
                if empty
                    then pure (Process.Finished Nothing)
                    else Process.Finished . Just <$> Stream.copyFile (Process.captureOut cap) fsPath
            case copied of
                Nothing -> pure (statusResponse 409 "Conflict" "cannot read that revision\n")
                Just (Left _) -> pure (statusResponse 500 "Internal Server Error" "could not restore that revision\n")
                Just (Right ()) -> do
                    Iteratee.liftIO (maint (Maintenance.Saved path))
                    let author = Identity.currentIdentity (Structure.versioningIdentity versioning) request
                    _ <- Iteratee.liftIO (Git.commitAll root author ("Roll back " ++ path ++ " to " ++ rev))
                    -- Rollback is a plain history-page form post: classic POST -> 303 -> GET.
                    pure (seeOtherResponse ("/documents/" ++ path))

{- | Answers @GET /search?q=...@ (RFC-0034): the search page with its form
and, for a non-empty query, the fused hybrid results -- one per page, best
chunk excerpted -- plus the indexing-in-progress note whenever the re-index
queue is non-empty. With search disabled it says so rather than 404ing.
-}
treeSearchHandler :: Maybe SearchIndex.SearchRuntime -> Router.Handler
treeSearchHandler search _captures request = do
    let query = capture "q" (Http.requestQuery request)
        wantsJson = hasQueryFlag "json" request
        -- The page that opened the search view, so "back" returns there rather than the root.
        origin = originFromReferer request
    case search of
        Nothing ->
            if wantsJson
                then pure (jsonResponse (Json.object [("enabled", Json.bool False)]))
                else pure (documentResponse (View.searchPage origin query Nothing))
        Just runtime -> do
            outcome <-
                if null query
                    then pure (Right [])
                    else Iteratee.liftIO (SearchIndex.searchQuery runtime query searchResultLimit)
            depth <- Iteratee.liftIO (SearchIndex.searchDepth runtime)
            case outcome of
                Left err ->
                    pure (statusResponse 500 "Internal Server Error" ("search failed: " ++ err ++ "\n"))
                Right hits
                    | wantsJson -> pure (jsonResponse (searchResultsJson depth hits))
                    | otherwise ->
                        pure (documentResponse (View.searchPage origin query (Just (hits, depth))))

-- | The most results a search answers with (one per page).
searchResultLimit :: Int
searchResultLimit = 20

{- | Search results as JSON for the editor's interactive search box: the
enabled marker, the re-index queue depth, and per hit the page path, its
display title and section heading (from the chunk's context line), and a
one-line excerpt.
-}
searchResultsJson :: Int -> [Store.Hit] -> Json.Json
searchResultsJson pending hits =
    Json.object
        [ ("enabled", Json.bool True)
        , ("pending", Json.int pending)
        , ("results", Json.array (map one hits))
        ]
  where
    one hit =
        Json.object
            [ ("path", Json.string (Store.hitPage hit))
            , ("title", Json.string (titleOfHit hit))
            , ("anchor", Json.string (Store.hitAnchor hit))
            , ("excerpt", Json.string (View.excerptOf (Store.hitText hit)))
            ]

-- | A hit's page title: the context line's first @ > @-separated segment.
titleOfHit :: Store.Hit -> String
titleOfHit hit = firstSegment (takeWhile (/= '\n') (Store.hitText hit))
  where
    firstSegment s =
        case breakOn " > " s of
            (before, _) -> before
    breakOn sep s
        | take (length sep) s == sep = ("", drop (length sep) s)
        | otherwise = case s of
            [] -> ("", "")
            (c : rest) -> let (b, a) = breakOn sep rest in (c : b, a)

{- | Sync the page's @images.yaml@ @short_title@s to the alt-derived values the
editor sends with a tree save (RFC-0019, ADR-0049): @image_count@ indexed
@image_path_<i>@/@image_title_<i>@ form fields. Each update is surgical and
update-only -- an unmatched @local_path@ or an unchanged value writes nothing
(and a save without the fields, e.g. a no-JavaScript post, is a no-op). The count
is capped so a crafted value cannot drive an unbounded loop.
-}
syncImageTitles :: FilePath -> TreePath.TreePath -> [(String, String)] -> IO ()
syncImageTitles root page fields =
    mapM_ (applyImageTitle (DocumentMeta.metaDirectoryFor root page) fields) [0 .. imageCount fields - 1]

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

-- | The @Content-Type@ header a document page carries.
documentHtmlHeaders :: [Http.Header]
documentHtmlHeaders = [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/html")]

-- | The block size, in bytes, for counting and streaming a document's escaped bytes.
docBlockBytes :: Int
docBlockBytes = 65536

{- | A document page streamed in constant memory (RFC-0040): the shell before the
content, the document escaped and streamed from disk a block at a time, then the
shell after, behind an exact @Content-Length@ summed from the shells' lengths and
the document's escaped length (a first pass counts it without holding the file).
The document is never held whole. A file that will not open (it vanished between
the existence check and here) is a @404@.
-}
documentFileResponse :: Html.Html () -> Html.Html () -> FilePath -> IO Http.Response
documentFileResponse beforeHtml afterHtml fsPath =
    orNotFound <$> Http.transformedFileResponse Http.okStatus documentHtmlHeaders (documentShellBytes beforeHtml) documentEscaper fsPath (documentSuffixBytes afterHtml)

{- | As 'documentFileResponse', but for a temporary capture served once (a
document at a git revision, RFC-0040): the streaming pass removes the file when
the body finishes, and a count failure removes it before the @404@. The caller
still owns any sibling capture (e.g. the stderr file) and removes that itself.
-}
documentTempFileResponse :: Html.Html () -> Html.Html () -> FilePath -> IO Http.Response
documentTempFileResponse beforeHtml afterHtml tmpPath =
    orNotFound <$> Http.transformedTempFileResponse Http.okStatus documentHtmlHeaders (documentShellBytes beforeHtml) documentEscaper tmpPath (documentSuffixBytes afterHtml)

{- | A document page whose content is already in memory -- the new-page seed, the
one document that is not a file -- escaped once and emitted as a sized stream, so
its response takes the same shape as a page streamed from disk (RFC-0040, RFC-0049).
Every other page (published, drafted, or captured from git) streams from its file.
-}
documentBytesResponse :: Html.Html () -> Html.Html () -> BS.ByteString -> IO Http.Response
documentBytesResponse beforeHtml afterHtml content =
    Http.transformedBytesResponse Http.okStatus documentHtmlHeaders (documentShellBytes beforeHtml) Html.escapeBlockBytes content (documentSuffixBytes afterHtml)

-- | The document block transform: the HTML escaper and its matching escaped-length, block by block (RFC-0049).
documentEscaper :: Http.BlockTransform
documentEscaper = Http.BlockTransform docBlockBytes Html.escapeBlockBytes Html.escapedLength

-- | The @after@ shell bytes (the suffix a document streams after its content).
documentSuffixBytes :: Html.Html () -> BS.ByteString
documentSuffixBytes afterHtml = BS.concat (Html.renderChunksRaw afterHtml)

-- | Maps a framework streamed-response failure (the file vanished before the count) to a @404@.
orNotFound :: Either Stream.StreamError Http.Response -> Http.Response
orNotFound (Right response) = response
orNotFound (Left _) = treeNotFound

{- | The chrome the editor shell carries around a page besides the document itself:
its attachments, breadcrumbs, tree spine and browser-tab title.
-}
data PageChrome = PageChrome
    { chromeAttachments :: [(String, String)]
    , chromeBreadcrumbs :: [View.Crumb]
    , chromeSpine :: String
    , chromeTitle :: String
    }

{- | Loads a page's chrome from its leading frontmatter block (the whole content
serves too, when it is already in hand). A new page takes the seed title.
-}
pageChrome :: FilePath -> TreePath.TreePath -> Bool -> BS.ByteString -> IO PageChrome
pageChrome root page isNew block = do
    attachments <- loadPageAttachments root page
    breadcrumbs <- breadcrumbsFor root page block
    spine <- treeSpineFor root page
    title <- documentPageTitle isNew (TreePath.render page) block
    pure (PageChrome attachments breadcrumbs spine title)

{- | The editor shell halves around the document hole for a page: the request's
editor mode, the versioning, editable and draft flags, and the page's chrome.
-}
shellFor :: TreePath.TreePath -> Http.RequestHead -> Bool -> Bool -> Bool -> PageChrome -> (Html.Html (), Html.Html ())
shellFor page request versioned editable hasDraft chrome =
    View.editorShell (TreePath.render page) (editorMode request) (chromeTitle chrome) versioned editable hasDraft (chromeAttachments chrome) (chromeBreadcrumbs chrome) (chromeSpine chrome)

{- | Whether a subprocess capture yielded nothing to serve: the command failed, or
its stdout capture is missing or empty. @git show@ exits non-zero when the path did
not exist at the revision, and the byte-returning path this replaced mapped both
that and an empty file to empty bytes, so this is the same predicate (RFC-0040).
-}
captureEmpty :: Process.ProcCapture -> IO Bool
captureEmpty cap = do
    stat <- FileSystem.fileStat (Process.captureOut cap)
    pure (Process.captureExit cap /= Exit.ExitSuccess || either (const True) ((== 0) . FileSystem.fsSize) stat)

-- | The @before@ shell bytes, with the HTML5 doctype 'documentResponse' prepends.
documentShellBytes :: Html.Html () -> BS.ByteString
documentShellBytes beforeHtml = BS.concat (BS.pack "<!doctype html>" : Html.renderChunksRaw beforeHtml)

-- | A @303 See Other@ redirect to the given location, with an empty body.
seeOtherResponse :: String -> Http.Response
seeOtherResponse location =
    Http.Response
        (Http.Status 303 "See Other")
        [(Http.normaliseHeaderName (BS.pack "Location"), BS.pack location)]
        (Http.StrictBody (BS.pack ""))

-- | The first value bound to a capture/field key, or @""@ when absent.
capture :: String -> Router.Captures -> String
capture _ [] = ""
capture name ((key, value) : rest)
    | name == key = value
    | otherwise = capture name rest

{- | Writes a document's bytes verbatim from a one-char-per-byte 'String'. Documents are
handled as bytes, never decoded: MicroHs's 'writeFile' would re-encode Unicode characters
as UTF-8, corrupting content that was read as raw bytes. Reading and writing the raw bytes
keeps the file byte-exact end to end -- the same property the static @?raw@/asset serving
already has.
-}
writeDocumentText :: FilePath -> String -> IO ()
writeDocumentText path content = writeDocumentBytes path (Utf8.encodeText content)

-- | Writes a document's bytes verbatim, with no widening through a 'String'.
writeDocumentBytes :: FilePath -> BS.ByteString -> IO ()
writeDocumentBytes = BS.writeFile

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

{- | Consumes an @application/x-www-form-urlencoded@ request body whose fields are
all small identifiers, as decoded 'String' pairs (RFC-0042). Every field is
collected; @cap@ bounds each decoded field and the total of every name and
value, so the body is bounded as the strict read it replaces was. The count cap
of one more than @cap@ catches the one shape the byte total cannot, a run of
empty fields (@&&&@), which add no bytes. Only the decoded fields are widened.
-}
formFieldsI :: Int -> Iteratee.Iter Stream.StreamError [(String, String)]
formFieldsI cap = do
    result <- Form.formI limits (Stream.StreamParseError Parse.BodyTooLarge) (const Form.CollectField)
    -- decoded (RFC-0043): a field value is a title or a tree path in real characters, never bytes as Chars
    pure [(Utf8.decodeBytes key, Utf8.decodeBytes value) | (key, value) <- Form.collectedFields result]
  where
    limits = Form.FormLimits{Form.maxFieldBytes = cap, Form.maxCollectedBytes = cap, Form.maxFields = cap + 1}

{- | The browser-tab title for a document page: the page's frontmatter
@name@, falling back to the humanised filename for an untitled page.
-}
documentPageTitle :: Bool -> String -> BS.ByteString -> IO String
documentPageTitle isNew docId content
    | isNew = pure "New page"
    | otherwise = do
        block <- Frontmatter.slice content
        pure
            ( Maybe.fromMaybe
                (humaniseSegment (lastSegment docId))
                (Frontmatter.titleOf block)
            )

-- | The seed Markdown for a new or missing document.
seededMarkdown :: String
seededMarkdown =
    "# Hello from MicroHttp\n\nEdit this Markdown document."
