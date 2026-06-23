{-# LANGUAGE OverloadedStrings #-}

module MicroHttp.TestApp (
    DocumentStore (..),
    NodeKind (..),
    TreeNode (..),
    app,
    appFromConfig,
    appWith,
    appWithDocumentRoot,
    appWithDocumentTree,
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

import qualified Data.ByteString.Char8 as BS
import Data.Char (digitToInt, isAsciiLower, isAsciiUpper, isDigit, isSpace, toLower, toUpper)
import Data.List (intercalate, isSuffixOf, sortBy)
import Data.Maybe (catMaybes, fromMaybe)
import MicroHttp.Attachment (allowedExtension, attachmentRoutes, extensionOf, fileAttachmentStore, inlineImageExtension, originalUploadFilename, uploadFilename)
import MicroHttp.Config (Config, configInt, configMounts, configString)
import qualified MicroHttp.DocumentMeta as DocumentMeta
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http as Http
import MicroHttp.Http.Parse (ParseError (..))
import MicroHttp.Http.PercentEncoding (decodeFormValue)
import MicroHttp.Iteratee (Iter, liftIO, readBodyStrict)
import MicroHttp.Log (Logger, localTimestamp, rotatingAppender, rotatingFileLogfmtLogger)
import MicroHttp.Middleware (logRequests, withErrorResponses)
import MicroHttp.Network.Socket (ConnectionInfo (..), Host (..), fileSizeBytes)
import MicroHttp.OperationLog (OpType (..), Operation (..), appendOperation, nextSeq, readOperations)
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import qualified MicroHttp.Static as Static
import MicroHttp.Stream (StreamError (..))
import MicroHttp.TreeMove (DeleteOutcome (..), MovePlan (..), deleteTarget, movePage, movePlanJson, moveSection, restoreFromTrash)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)

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
appWith :: Logger -> Server.Application
appWith logger =
    logRequests logger (withErrorResponses app)

{- | The application composed from configuration (RFC-0011): the access-log
path, document root, and static mounts come from the config, and the parse
limits from the (config-derived) settings. Logging is the outermost middleware.
-}
appFromConfig :: Server.Settings -> Config -> IO Server.Application
appFromConfig settings cfg = do
    accessLogger <- rotatingFileLogfmtLogger logMaxBytes logKeep accessLogPath
    clientErrorSink <- rotatingAppender logMaxBytes logKeep clientErrorLogPath
    pure
        ( logRequests
            accessLogger
            ( withErrorResponses
                ( Router.serveRoutes
                    (Server.parseLimits settings)
                    (configuredRoutes cfg clientErrorSink)
                )
            )
        )
  where
    accessLogPath = configString "access_log" "build/access.log" cfg
    clientErrorLogPath = configString "client_error_log" "build/client-errors.log" cfg
    logMaxBytes = configIntOr "log_max_bytes" defaultLogMaxBytes cfg
    logKeep = configIntOr "log_keep" defaultLogKeep cfg

-- | The default log-rotation threshold in bytes (10 MiB) and retained-file count (RFC-0024).
defaultLogMaxBytes :: Int
defaultLogMaxBytes = 10485760

defaultLogKeep :: Int
defaultLogKeep = 5

-- | A total config-int read: the default on an absent or malformed value.
configIntOr :: String -> Int -> Config -> Int
configIntOr key def cfg = case configInt key def cfg of
    Right value -> value
    Left _ -> def

{- | The route set chosen by configuration. Setting @document_tree_root@ selects
the filesystem-tree mode (a MkDocs-style tree served and edited in place, with
per-page peer @assets/@); otherwise the flat single-document store is used.
-}
configuredRoutes :: Config -> (String -> IO ()) -> [Router.Route]
configuredRoutes cfg clientErrorSink =
    clientErrorRoute clientErrorSink
        : case configString "document_tree_root" "" cfg of
            "" ->
                documentRoutes editorTheme (configString "document_root" "data/documents" cfg)
                    ++ attachmentRoutes (fileAttachmentStore (configString "attachment_root" "data/attachments" cfg))
                    ++ mounts
            treeRoot ->
                treeRoutes editorTheme treeRoot logPath trashRoot ++ mounts
  where
    editorTheme = configString "editor_theme" "paper" cfg
    logPath = configString "operation_log" "data/operation_log" cfg
    trashRoot = configString "trash_root" "data/trash" cfg
    mounts = [Static.static prefix root | (prefix, root) <- configMounts "static_mounts" cfg]

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

appWithStore :: DocumentStore -> Server.Application
appWithStore store =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        (routes "paper" store ++ attachmentRoutes (fileAttachmentStore "data/attachments"))

routes :: String -> DocumentStore -> [Router.Route]
routes editorThemeDefault store =
    [ Router.get "/" index
    , Router.get "/index.html" index
    , Router.get "/documents/:id/edit" (editDocument editorThemeDefault store)
    , Router.get "/documents/:id" (showDocument store)
    , Router.post "/documents/:id" (saveDocument editorThemeDefault store)
    , Static.static "/static/editor" "static/editor"
    ]

{- | Routes that serve and edit a documentation tree on the filesystem. The whole
tree is reachable under @/documents/@; the editor opens at a document's own URL
with @?edit@ (so the page's base path is the file's directory and relative
@assets/...@ links resolve to the real files); a @POST@ writes the @.md@ back;
and every other tree file (images, attachments, raw Markdown) is served
statically and path-safely (reusing 'Static.resolveStaticPath'). The document id
is the tree-relative path including the @.md@ extension.
-}
treeRoutes :: String -> FilePath -> FilePath -> FilePath -> [Router.Route]
treeRoutes editorThemeDefault root logPath trashRoot =
    [ Router.get "/" (redirectTo "/documents/")
    , Router.get "/index.html" (redirectTo "/documents/")
    , Static.static "/static/editor" "static/editor"
    , Router.get "/tree/*path" (treeChildrenHandler root)
    , Router.post "/tree/*path" (treePostDispatch root logPath trashRoot)
    , Router.post "/trash/*id" (treeRestoreHandler root logPath trashRoot)
    , Router.post "/undo" (treeUndoHandler root logPath trashRoot)
    , Router.post "/documents/*path" (treePost root)
    , Router.get "/documents/*path" (treeGet editorThemeDefault root)
    ]

{- | The navigation-tree children endpoint (RFC-0026): @GET /tree/*path@ returns
the immediate children of the folder at the tree-relative path (empty for the
root) as JSON, read live from the filesystem.
-}
treeChildrenHandler :: FilePath -> Router.Handler
treeChildrenHandler root captures _ = do
    nodes <- liftIO (childrenOf root (capture "path" captures))
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
treeCreateHandler :: FilePath -> Router.Handler
treeCreateHandler root captures _ = do
    bytes <- readBodyStrict (StreamParseError BodyTooLarge) treeCreateMaxBytes
    let fields = formFields (BS.unpack bytes)
    result <- liftIO (createTreeNode root (capture "path" captures) (capture "kind" fields) (capture "title" fields))
    pure (either (statusResponse 400 "Bad Request") id result)

{- | Dispatches a @POST /tree/*path@: a section/page move when the @?move@ flag is
present (RFC-0027), otherwise a create (RFC-0026).
-}
treePostDispatch :: FilePath -> FilePath -> FilePath -> Router.Handler
treePostDispatch root logPath trashRoot captures request
    | hasQueryFlag "move" request = treeMoveHandler root logPath captures
    | hasQueryFlag "delete" request = treeDeleteHandler root logPath trashRoot captures
    | otherwise = treeCreateHandler root captures request

{- | The section-move endpoint (RFC-0027): @POST /tree/*path?move@ with form fields
@to@ (destination parent tree path), @slug@ (optional new slug), and @confirm@
(@true@ to apply, otherwise a dry-run preview). Returns the impact plan as JSON, or a
@409@ with the reason on refusal (root, cycle, collision, unsafe path).
-}
treeMoveHandler :: FilePath -> FilePath -> Router.Captures -> Iter StreamError Http.Response
treeMoveHandler root logPath captures = do
    bytes <- readBodyStrict (StreamParseError BodyTooLarge) treeCreateMaxBytes
    let fields = formFields (BS.unpack bytes)
        srcRel = capture "path" captures
        confirm = capture "confirm" fields == "true"
        isPage = isMarkdownPath srcRel
        move = if isPage then movePage else moveSection
    result <- liftIO (move root srcRel (capture "to" fields) (capture "slug" fields) confirm)
    liftIO (recordAppliedMove logPath isPage result)
    pure (either (statusResponse 409 "Conflict" . (++ "\n")) (jsonResponse . movePlanJson) result)

{- | Appends a @move@ record to the operation log after a move was applied
(apply-then-append, RFC-0028); a preview or a refusal logs nothing. The log's parent
directory is created on demand.
-}
recordAppliedMove :: FilePath -> Bool -> Either String MovePlan -> IO ()
recordAppliedMove logPath isPage (Right plan)
    | planApplied plan = do
        createDirectoryIfMissing True (parentDirectory logPath)
        seq' <- nextSeq logPath
        ts <- localTimestamp
        appendOperation
            logPath
            Operation
                { opType = OpMove
                , opKind = if isPage then "page" else "section"
                , opFrom = Just (planFrom plan)
                , opTo = Just (planTo plan)
                , opSeq = seq'
                , opTs = ts
                , opTrash = Nothing
                }
recordAppliedMove _ _ _ = pure ()

{- | The delete endpoint (RFC-0027 phase 4 + RFC-0028 trash): @POST /tree/*path?delete@.
Refuses with @409@ and the referrer list when another page links in; otherwise moves
the target to trash, appends a @delete@ record to the operation log, and returns the
trash id. The trash id is the delete record's @seq@.
-}
treeDeleteHandler :: FilePath -> FilePath -> FilePath -> Router.Captures -> Iter StreamError Http.Response
treeDeleteHandler root logPath trashRoot captures = liftIO $ do
    let path = capture "path" captures
        isPage = isMarkdownPath path
    seqNo <- logSeq logPath
    result <- deleteTarget root trashRoot path (show seqNo) seqNo
    case result of
        Left err -> pure (statusResponse 409 "Conflict" (err ++ "\n"))
        Right (Refused referrers) -> pure (statusResponse 409 "Conflict" (referrersJson referrers))
        Right (Deleted tid p _) -> do
            ts <- localTimestamp
            appendOp
                logPath
                Operation
                    { opType = OpDelete
                    , opKind = kindLabel isPage
                    , opFrom = Just p
                    , opTo = Nothing
                    , opSeq = seqNo
                    , opTs = ts
                    , opTrash = Just tid
                    }
            pure (jsonResponse ("{\"deleted\":" ++ jsonString p ++ ",\"trashId\":" ++ jsonString tid ++ "}"))

{- | The restore endpoint (RFC-0028): @POST /trash/*id@ moves a trashed entry back to
its origin (re-adding the listing), appends a @restore@ record, and returns the
restored path; a @409@ if the origin is now occupied or the entry is missing.
-}
treeRestoreHandler :: FilePath -> FilePath -> FilePath -> Router.Handler
treeRestoreHandler root logPath trashRoot captures _ = liftIO $ do
    let trashId = capture "id" captures
    result <- restoreFromTrash root trashRoot trashId
    case result of
        Left err -> pure (statusResponse 409 "Conflict" (err ++ "\n"))
        Right (path, kind) -> do
            seqNo <- logSeq logPath
            ts <- localTimestamp
            appendOp
                logPath
                Operation
                    { opType = OpRestore
                    , opKind = kind
                    , opFrom = Nothing
                    , opTo = Just path
                    , opSeq = seqNo
                    , opTs = ts
                    , opTrash = Just trashId
                    }
            pure (jsonResponse ("{\"restored\":" ++ jsonString path ++ "}"))

-- | @"page"@ or @"section"@ for the operation log.
kindLabel :: Bool -> String
kindLabel isPage = if isPage then "page" else "section"

-- | The next operation-log sequence number, creating the log's parent directory on demand.
logSeq :: FilePath -> IO Int
logSeq logPath = do
    createDirectoryIfMissing True (parentDirectory logPath)
    nextSeq logPath

-- | Appends an operation to the log, creating its parent directory on demand.
appendOp :: FilePath -> Operation -> IO ()
appendOp logPath op = do
    createDirectoryIfMissing True (parentDirectory logPath)
    appendOperation logPath op

-- | A refused-delete body: the referrers as @{"refused":true,"referrers":[{"page","link"}]}@.
referrersJson :: [(String, String)] -> String
referrersJson referrers =
    "{\"refused\":true,\"referrers\":["
        ++ intercalate "," (map one referrers)
        ++ "]}"
  where
    one (page, link) = "{\"page\":" ++ jsonString page ++ ",\"link\":" ++ jsonString link ++ "}"

{- | The undo endpoint (RFC-0028 phase 3): @POST /undo@ applies the inverse of the
latest logged operation and appends that inverse as a new record (undo is itself a
logged operation, so a further undo is a redo). The inverse of a move is the reverse
move; of a delete, a restore; of a restore, a delete. A @409@ when the log is empty
or the inverse cannot be applied (e.g. its target is occupied or now referenced).
-}
treeUndoHandler :: FilePath -> FilePath -> FilePath -> Router.Handler
treeUndoHandler root logPath trashRoot _ _ = liftIO $ do
    ops <- readOperations logPath
    case reverse ops of
        [] -> pure (statusResponse 409 "Conflict" "nothing to undo\n")
        (latest : _) -> do
            result <- applyInverse root logPath trashRoot latest
            pure (either (statusResponse 409 "Conflict" . (++ "\n")) jsonResponse result)

{- | Applies the inverse of an operation through the move/trash machinery and appends
the inverse record, returning the JSON body on success or an error reason.
-}
applyInverse :: FilePath -> FilePath -> FilePath -> Operation -> IO (Either String String)
applyInverse root logPath trashRoot op = case opType op of
    OpMove -> undoMove
    OpDelete -> undoDelete
    OpRestore -> undoRestore
  where
    from = fromMaybe "" (opFrom op)
    to = fromMaybe "" (opTo op)

    undoMove = do
        let destParent = parentOfRel from
            slug = slugForPath (opKind op) from
            move = if opKind op == "page" then movePage else moveSection
        result <- move root to destParent slug True
        case result of
            Left err -> pure (Left err)
            Right plan
                | planApplied plan -> do
                    appendInverse (opKind op) OpMove (Just to) (Just from) Nothing
                    pure (Right ("{\"undo\":\"move\",\"from\":" ++ jsonString to ++ ",\"to\":" ++ jsonString from ++ "}"))
                | otherwise -> pure (Left "inverse move was not applied")

    undoDelete = case opTrash op of
        Nothing -> pure (Left "delete record has no trash id")
        Just tid -> do
            result <- restoreFromTrash root trashRoot tid
            case result of
                Left err -> pure (Left err)
                Right (path, kind) -> do
                    appendInverse kind OpRestore Nothing (Just path) (Just tid)
                    pure (Right ("{\"undo\":\"delete\",\"restored\":" ++ jsonString path ++ "}"))

    undoRestore = do
        seqNo <- logSeq logPath
        result <- deleteTarget root trashRoot to (show seqNo) seqNo
        case result of
            Left err -> pure (Left err)
            Right (Refused _) -> pure (Left "cannot undo restore: the target is now referenced")
            Right (Deleted tid path _) -> do
                ts <- localTimestamp
                appendOp logPath (Operation OpDelete (kindOf to) (Just path) Nothing seqNo ts (Just tid))
                pure (Right ("{\"undo\":\"restore\",\"deleted\":" ++ jsonString path ++ ",\"trashId\":" ++ jsonString tid ++ "}"))

    -- Appends an inverse record with a fresh seq and timestamp.
    appendInverse kind typ opFrom' opTo' trash = do
        seqNo <- logSeq logPath
        ts <- localTimestamp
        appendOp
            logPath
            Operation
                { opType = typ
                , opKind = kind
                , opFrom = opFrom'
                , opTo = opTo'
                , opSeq = seqNo
                , opTs = ts
                , opTrash = trash
                }

-- | @"page"@ or @"section"@ for a tree path.
kindOf :: String -> String
kindOf path = kindLabel (isMarkdownPath path)

-- | The parent tree path of a tree path (its segments minus the last; @""@ at the root).
parentOfRel :: String -> String
parentOfRel path = intercalate "/" (initOrEmpty (pathSegments path))
  where
    initOrEmpty [] = []
    initOrEmpty xs = init xs

-- | The destination slug to move a path back to: a page's basename without @.md@, a section's last segment.
slugForPath :: String -> String -> String
slugForPath kind path =
    let name = lastOrEmpty (pathSegments path)
     in if kind == "page" && ".md" `isSuffixOf` name then take (length name - length ".md") name else name
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
        (treeRoutes editorThemeDefault root "data/operation_log" "data/trash")

{- | A GET under the tree: the editor page for @?edit@ on a Markdown file,
otherwise the file served statically (raw Markdown, images, attachments).
-}
treeGet :: String -> FilePath -> Router.Handler
treeGet editorThemeDefault root captures request
    | not (isMarkdownPath path) = treeServeFile root path
    | hasQueryFlag "edit" request = treeEdit editorThemeDefault root path request
    | hasQueryFlag "raw" request = treeServeFile root path
    | otherwise = treeRead editorThemeDefault root path request
  where
    -- The tree root (@/documents@ or @/documents/@) resolves to its @index.md@ page.
    path = case capture "path" captures of
        "" -> "index.md"
        captured -> captured

{- | Renders the editable editor for a tree document, loading its current content
(or a seed if the file is absent, so a missing page can be created by editing).
-}
treeEdit :: String -> FilePath -> String -> Http.RequestHead -> Iter StreamError Http.Response
treeEdit editorThemeDefault root path request =
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            exists <- liftIO (doesFileExist fsPath)
            content <- if exists then liftIO (BS.readFile fsPath) else pure (BS.pack seededMarkdown)
            attachments <- liftIO (loadPageAttachments root path)
            breadcrumbs <- liftIO (breadcrumbsFor root path (BS.unpack content))
            spine <- liftIO (treeSpineFor root path)
            pure (documentResponse (editorPage path (editorMode request) editorThemeDefault content True True attachments breadcrumbs spine Nothing))

{- | Renders the read-only view for a tree document (the default @GET@, RFC-0020):
the editor shell with editing disabled. A missing page is a @404@ -- reading never
seeds (that stays an @?edit@ affordance).
-}
treeRead :: String -> FilePath -> String -> Http.RequestHead -> Iter StreamError Http.Response
treeRead editorThemeDefault root path request =
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            exists <- liftIO (doesFileExist fsPath)
            if not exists
                then pure treeNotFound
                else do
                    content <- liftIO (BS.readFile fsPath)
                    attachments <- liftIO (loadPageAttachments root path)
                    breadcrumbs <- liftIO (breadcrumbsFor root path (BS.unpack content))
                    spine <- liftIO (treeSpineFor root path)
                    pure (documentResponse (editorPage path (editorMode request) editorThemeDefault content True False attachments breadcrumbs spine Nothing))

-- | Serves a tree file as a sized 'FileBody' with a type from its extension, or a @404@ when absent.
treeServeFile :: FilePath -> String -> Iter StreamError Http.Response
treeServeFile root path =
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            exists <- liftIO (doesFileExist fsPath)
            if not exists
                then pure treeNotFound
                else do
                    sized <- liftIO (fileSizeBytes fsPath)
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
treePost :: FilePath -> Router.Handler
treePost root captures request
    | hasQueryFlag "asset" request = treeUpload root captures request
    | otherwise = treeSave root captures request

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
    bytes <- readBodyStrict (StreamParseError BodyTooLarge) treeAssetMaxBytes
    let path = capture "path" captures
        name = uploadFilename request
    if not (allowedExtension (extensionOf name))
        then pure (statusResponse 415 "Unsupported Media Type" "attachment type is not allowed\n")
        else case assetsDirectoryFor root path of
            Nothing -> pure treeNotFound
            Just assetsDir -> do
                liftIO (createDirectoryIfMissing True assetsDir)
                stored <- liftIO (storeAsset assetsDir name bytes)
                liftIO (recordAssetMetadata root path stored (originalUploadFilename request))
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
            | inlineImageExtension extension -> DocumentMeta.appendImage metaDir localPath originalName
            | otherwise -> DocumentMeta.appendAttachment metaDir (DocumentMeta.AttachmentEntry originalName localPath extension)
  where
    localPath = "assets/" ++ stored
    extension = extensionOf stored

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
        exists <- doesFileExist target
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
attachmentsJson entries = "[" ++ intercalate "," (map attachmentObject entries) ++ "]"
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
        pure (Crumb (fromMaybe (folderFallback fp) name) (Just (folderHref fp)))
    folderFallback "" = "Cello"
    folderFallback fp = humaniseSegment (lastSegment fp)
    currentLabel = fromMaybe (humaniseSegment (lastSegment path)) (frontmatterTitle content)

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
    capitalise (c : cs) = toUpper c : cs
    dropExtension s = if ".md" `isSuffixOf` s then take (length s - 3) s else s

-- | Reads a folder's @index.md@ frontmatter title, or Nothing when the file is absent or untitled.
readIndexTitle :: FilePath -> String -> IO (Maybe String)
readIndexTitle root fp =
    case Static.resolveStaticPath root (pathSegments indexPath) of
        Nothing -> pure Nothing
        Just fsPath -> do
            exists <- doesFileExist fsPath
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
nameFieldValue line = case break (== ':') (dropWhile isSpace (stripCarriageReturn line)) of
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
trimSpace = f . f where f = reverse . dropWhile isSpace

-- | Drops a trailing carriage return (CRLF tolerance).
stripCarriageReturn :: String -> String
stripCarriageReturn s = if not (null s) && last s == '\r' then init s else s

-- | The breadcrumb trail as a JSON array of @{"label","href"}@ (href omitted for the current page).
breadcrumbsJson :: [Crumb] -> String
breadcrumbsJson crumbs = "[" ++ intercalate "," (map crumbObject crumbs) ++ "]"
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
orderTreeNodes = sortBy compareNodes
  where
    compareNodes a b = compare (sortKey a) (sortKey b)
    sortKey n = (kindRank (nodeKind n), map toLower (nodeName n))
    kindRank :: NodeKind -> Int
    kindRank Section = 0
    kindRank Page = 1

-- | The navigation-tree children as a JSON array of @{"name","path","kind","hasChildren"}@ (RFC-0026).
treeChildrenJson :: [TreeNode] -> String
treeChildrenJson nodes = "[" ++ intercalate "," (map nodeObject nodes) ++ "]"
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
            isDir <- doesDirectoryExist dirFs
            if not isDir
                then pure []
                else do
                    names <- listDirectory dirFs
                    nodes <- mapM (childNode root parentRel dirFs) names
                    pure (orderTreeNodes (catMaybes nodes))

-- | Builds a navigation-tree node for one directory entry, or 'Nothing' when it is hidden.
childNode :: FilePath -> String -> FilePath -> String -> IO (Maybe TreeNode)
childNode root parentRel dirFs name = do
    isDir <- doesDirectoryExist entryFs
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
    pure (fromMaybe (humaniseSegment name) title)

-- | A page's label: its frontmatter @name@, or a humanised filename.
pageLabel :: FilePath -> String -> String -> IO String
pageLabel root childRel name =
    case Static.resolveStaticPath root (pathSegments childRel) of
        Nothing -> pure (humaniseSegment name)
        Just fsPath -> do
            exists <- doesFileExist fsPath
            if not exists
                then pure (humaniseSegment name)
                else do
                    title <- fmap frontmatterTitle (readDocumentText fsPath)
                    pure (fromMaybe (humaniseSegment name) title)

-- | Whether a folder holds any entry the navigation tree would show (so a section is expandable).
dirHasVisibleChildren :: FilePath -> IO Bool
dirHasVisibleChildren dirFs = do
    names <- listDirectory dirFs
    anyVisible names
  where
    anyVisible [] = pure False
    anyVisible (n : ns) = do
        isDir <- doesDirectoryExist (dirFs ++ "/" ++ n)
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
    pure ("[" ++ intercalate "," entries ++ "]")
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
createTreeNode :: FilePath -> String -> String -> String -> IO (Either String Http.Response)
createTreeNode root parentRel kind title
    | null (trimSpace title) = pure (Left "missing title\n")
    | kind /= "page" && kind /= "section" = pure (Left "unknown kind\n")
    | otherwise =
        case Static.resolveStaticPath root (pathSegments parentRel) of
            Nothing -> pure (Left "unsafe path\n")
            Just parentFs -> do
                parentExists <- doesDirectoryExist parentFs
                if not parentExists
                    then pure (Left "parent not found\n")
                    else do
                        slug <- uniqueSlug parentFs (slugify title) (kind == "section")
                        let childRel = joinRel parentRel slug
                            seedBody = "---\nname: " ++ yamlScalar title ++ "\n---\n\n# " ++ title ++ "\n"
                        if kind == "section"
                            then do
                                createDirectoryIfMissing True (parentFs ++ "/" ++ slug)
                                writeDocumentText (parentFs ++ "/" ++ slug ++ "/index.md") seedBody
                                pure (Right (jsonResponse (createdJson title childRel "section" (childRel ++ "/index.md"))))
                            else do
                                writeDocumentText (parentFs ++ "/" ++ slug ++ ".md") seedBody
                                pure (Right (jsonResponse (createdJson title (childRel ++ ".md") "page" (childRel ++ ".md"))))

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
        | isAsciiLower c || isDigit c = c
        | isAsciiUpper c = toLower c
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
        then doesDirectoryExist (parentFs ++ "/" ++ slug)
        else doesFileExist (parentFs ++ "/" ++ slug ++ ".md")

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

jsonResponse :: String -> Http.Response
jsonResponse body =
    Http.Response Http.okStatus [contentTypeHeader "application/json"] (Http.StrictBody (BS.pack body))

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

clientErrorHandler :: (String -> IO ()) -> Router.Handler
clientErrorHandler sink _ request = do
    bytes <- readBodyStrict (StreamParseError BodyTooLarge) clientErrorMaxBytes
    let fields = formFields (BS.unpack bytes)
    liftIO $ do
        ts <- localTimestamp
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
clientPeerHost :: ConnectionInfo -> String
clientPeerHost conn = case connPeerHost conn of
    HostAny -> "0.0.0.0"
    HostIPv4 a b c d -> show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

{- | Saves a posted Markdown document back to its file in the tree, creating any
missing parent directories. Unlike the flat 'saveDocument', the tree mode does
not apply the raw-HTML guard: the tree holds the user's own trusted documents
(many carry export-metadata HTML comments and occasional markup), so rejecting
raw HTML would block legitimate saves -- the editor preserves it verbatim, and
nothing renders it as live HTML (the trust boundary that guard defends does not
apply to first-party files).
-}
treeSave :: FilePath -> Router.Handler
treeSave root captures request = do
    bodyBytes <- readBodyStrict (StreamParseError BodyTooLarge) formBodyLimit
    let fields = formFields (BS.unpack bodyBytes)
        markdown = normaliseNewlines (capture "markdown" fields)
        path = capture "path" captures
    case Static.resolveStaticPath root (pathSegments path) of
        Nothing -> pure treeNotFound
        Just fsPath -> do
            liftIO (createDirectoryIfMissing True (parentDirectory fsPath))
            liftIO (writeDocumentText fsPath markdown)
            liftIO (syncImageTitles root path fields)
            if isHtmxRequest request
                then pure (htmlResponseChunks (saveStatusFragment markdown))
                else pure (seeOtherResponse ("/documents/" ++ path ++ "?edit"))

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
    | not (null s) && all isDigit s = foldl (\acc c -> acc * 10 + digitToInt c) 0 s
    | otherwise = 0

-- | Whether a query flag (a key, with or without a value) is present in the request query.
hasQueryFlag :: String -> Http.RequestHead -> Bool
hasQueryFlag name request =
    any (\(key, _) -> key == name) (Http.requestQuery request)

-- | Whether a tree path names a Markdown document.
isMarkdownPath :: String -> Bool
isMarkdownPath path =
    ".md" `isSuffixOf` path

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

contentTypeHeader :: String -> Http.Header
contentTypeHeader value =
    (Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack value)

treeNotFound :: Http.Response
treeNotFound =
    Http.Response
        (Http.Status 404 "Not Found")
        [contentTypeHeader "text/plain"]
        (Http.StrictBody (BS.pack "not found\n"))

index :: Router.Handler
index _ _ =
    pure (documentResponse indexPage)

editDocument :: String -> DocumentStore -> Router.Handler
editDocument editorThemeDefault store captures request = do
    let docId = documentId captures
    content <- liftIO (loadDocument store docId)
    pure (documentResponse (editorPage docId (editorMode request) editorThemeDefault (BS.pack content) False True [] [] "" Nothing))

showDocument :: DocumentStore -> Router.Handler
showDocument store captures _ = do
    markdown <- liftIO (loadDocument store (documentId captures))
    pure (markdownResponse markdown)

{- | Saves a posted Markdown document, answering both htmx and ordinary form
posts from one route (RFC-0001). An htmx request (the @hx-request@ header is
present) keeps the status-fragment behaviour; an ordinary form post follows
post-redirect-get on success (@303@ back to the edit page) and re-renders the
edit page with the validation message and the submitted Markdown on failure.
-}
saveDocument :: String -> DocumentStore -> Router.Handler
saveDocument editorThemeDefault store captures request = do
    bodyBytes <- readBodyStrict (StreamParseError BodyTooLarge) formBodyLimit
    let markdown = markdownFromBody bodyBytes
        docId = documentId captures
    case validateMarkdown markdown of
        Just err
            | isHtmxRequest request -> pure (htmlResponseChunks (validationStatusFragment err))
            | otherwise ->
                pure (documentResponse (editorPage docId Nothing editorThemeDefault (BS.pack markdown) False True [] [] "" (Just err)))
        Nothing -> do
            liftIO (saveDocumentContent store docId markdown)
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

capture :: String -> Router.Captures -> String
capture _ [] = ""
capture name ((key, value) : rest)
    | name == key = value
    | otherwise = capture name rest

documentId :: Router.Captures -> String
documentId =
    capture "id"

loadFileDocument :: FilePath -> String -> IO String
loadFileDocument root name = do
    let path = documentPath root name
    exists <- doesFileExist path
    if exists
        then readDocumentText path
        else return seededMarkdown

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

writeDocumentText :: FilePath -> String -> IO ()
writeDocumentText path content = BS.writeFile path (BS.pack content)

documentPath :: FilePath -> String -> FilePath
documentPath root name =
    root ++ "/" ++ name ++ ".md"

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

formFields :: String -> [(String, String)]
formFields "" = []
formFields body =
    map parseField (splitOn '&' body)

parseField :: String -> (String, String)
parseField field =
    case break (== '=') field of
        (key, '=' : value) -> (decodeFormValue key, decodeFormValue value)
        (key, _) -> (decodeFormValue key, "")

splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]

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
                Html.custom "status-card" [Html.attr "data-state" "ok"] "Served by src/TestApp.hs"

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
    "[" ++ intercalate "," (map (\item -> "'" ++ item ++ "'") items) ++ "]"

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
editorPage :: String -> Maybe String -> String -> BS.ByteString -> Bool -> Bool -> [(String, String)] -> [Crumb] -> String -> Maybe String -> Html.Html ()
editorPage docId mode themeDefault content treeMode editable attachments breadcrumbs treeSpine maybeError =
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
                            editorElement docId mode treeMode editable attachments breadcrumbs treeSpine content
                            Html.custom "noscript" [] $
                                Html.button_ [Html.attr "type" "submit"] (Html.text "Save")
                    else editorElement docId mode treeMode editable attachments breadcrumbs treeSpine content

{- | The @\<markdown-editor\>@ custom element with its server-set attributes and the
no-script @\<textarea\>@ fallback holding the document. @data-readonly@ is set in the
read view (RFC-0020); the element disables editing and hides the editing chrome.
-}
editorElement :: String -> Maybe String -> Bool -> Bool -> [(String, String)] -> [Crumb] -> String -> BS.ByteString -> Html.Html ()
editorElement docId mode treeMode editable attachments breadcrumbs treeSpine content =
    Html.custom
        "markdown-editor"
        ( [Html.attr "name" "markdown", Html.attr "data-document" docId]
            ++ maybe [] (\m -> [Html.attr "mode" m]) mode
            ++ [Html.attr "data-document-mode" "tree" | treeMode]
            ++ [Html.attr "data-attachments" (attachmentsJson attachments) | treeMode, not (null attachments)]
            ++ [Html.attr "data-breadcrumbs" (breadcrumbsJson breadcrumbs) | not (null breadcrumbs)]
            ++ [Html.attr "data-tree-spine" treeSpine | treeMode, not (null treeSpine)]
            ++ [Html.attr "data-readonly" "" | not editable]
        )
        ( Html.custom
            "textarea"
            [Html.attr "name" "markdown", Html.attr "aria-label" "Markdown source", Html.class_ "markdown-editor__fallback"]
            (Html.bytesText content)
        )

seededMarkdown :: String
seededMarkdown =
    "# Hello from MicroHttp\n\nEdit this Markdown document."

saveStatusFragment :: String -> Html.Html ()
saveStatusFragment markdown =
    Html.p [Html.attr "id" "save-status"] $ do
        Html.text "Saved Markdown document: "
        Html.text markdown

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

containsRawHtml :: String -> Bool
containsRawHtml [] = False
containsRawHtml ('<' : _) = True
containsRawHtml (_ : rest) = containsRawHtml rest

trim :: String -> String
trim =
    reverse . trimStart . reverse . trimStart

trimStart :: String -> String
trimStart =
    dropWhile isSpace
