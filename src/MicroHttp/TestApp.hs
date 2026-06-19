{-# LANGUAGE OverloadedStrings #-}

module MicroHttp.TestApp (
    DocumentStore (..),
    app,
    appFromConfig,
    appWith,
    appWithDocumentRoot,
    appWithDocumentTree,
    appWithStore,
    documentRoutes,
    fileStore,
    routes,
    treeRoutes,
) where

import qualified Data.ByteString.Char8 as BS
import Data.Char (digitToInt, isDigit, isSpace)
import Data.List (intercalate, isSuffixOf)
import MicroHttp.Attachment (allowedExtension, attachmentRoutes, extensionOf, fileAttachmentStore, inlineImageExtension, originalUploadFilename, uploadFilename)
import MicroHttp.Config (Config, configMounts, configString)
import qualified MicroHttp.DocumentMeta as DocumentMeta
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http as Http
import MicroHttp.Http.Parse (ParseError (..))
import MicroHttp.Http.PercentEncoding (decodeFormValue)
import MicroHttp.Iteratee (Iter, liftIO, readBodyStrict)
import MicroHttp.Log (Logger, fileLogfmtLogger)
import MicroHttp.Middleware (logRequests, withErrorResponses)
import MicroHttp.Network.Socket (fileSizeBytes)
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import qualified MicroHttp.Static as Static
import MicroHttp.Stream (StreamError (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)

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
appFromConfig :: Server.Settings -> Config -> Server.Application
appFromConfig settings cfg =
    logRequests
        (fileLogfmtLogger (configString "access_log" "build/access.log" cfg))
        ( withErrorResponses
            ( Router.serveRoutes
                (Server.parseLimits settings)
                (configuredRoutes cfg)
            )
        )

{- | The route set chosen by configuration. Setting @document_tree_root@ selects
the filesystem-tree mode (a MkDocs-style tree served and edited in place, with
per-page peer @assets/@); otherwise the flat single-document store is used.
-}
configuredRoutes :: Config -> [Router.Route]
configuredRoutes cfg =
    case configString "document_tree_root" "" cfg of
        "" ->
            documentRoutes editorTheme (configString "document_root" "data/documents" cfg)
                ++ attachmentRoutes (fileAttachmentStore (configString "attachment_root" "data/attachments" cfg))
                ++ mounts
        treeRoot ->
            treeRoutes editorTheme treeRoot ++ mounts
  where
    editorTheme = configString "editor_theme" "paper" cfg
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
treeRoutes :: String -> FilePath -> [Router.Route]
treeRoutes editorThemeDefault root =
    [ Router.get "/" (redirectTo "/documents/")
    , Router.get "/index.html" (redirectTo "/documents/")
    , Static.static "/static/editor" "static/editor"
    , Router.post "/documents/*path" (treePost root)
    , Router.get "/documents/*path" (treeGet editorThemeDefault root)
    ]

-- | A handler that redirects to a fixed location (a @303 See Other@ to a GET target).
redirectTo :: String -> Router.Handler
redirectTo location _ _ = pure (seeOtherResponse location)

-- | The bare tree-serving application (no middleware), for tests and embedding.
appWithDocumentTree :: String -> FilePath -> Server.Application
appWithDocumentTree editorThemeDefault root =
    Router.serveRoutes
        (Server.parseLimits Server.defaultSettings)
        (treeRoutes editorThemeDefault root)

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
            pure (documentResponse (editorPage path (editorMode request) editorThemeDefault content True True attachments Nothing))

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
                    pure (documentResponse (editorPage path (editorMode request) editorThemeDefault content True False attachments Nothing))

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

jsonResponse :: String -> Http.Response
jsonResponse body =
    Http.Response Http.okStatus [contentTypeHeader "application/json"] (Http.StrictBody (BS.pack body))

statusResponse :: Int -> String -> String -> Http.Response
statusResponse code reason body =
    Http.Response (Http.Status code reason) [contentTypeHeader "text/plain"] (Http.StrictBody (BS.pack body))

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
    pure (documentResponse (editorPage docId (editorMode request) editorThemeDefault (BS.pack content) False True [] Nothing))

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
                pure (documentResponse (editorPage docId Nothing editorThemeDefault (BS.pack markdown) False True [] (Just err)))
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
knownEditorThemes = ["paper", "aurora", "blueprint", "herbarium", "workbench", "studio"]

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
editorPage :: String -> Maybe String -> String -> BS.ByteString -> Bool -> Bool -> [(String, String)] -> Maybe String -> Html.Html ()
editorPage docId mode themeDefault content treeMode editable attachments maybeError =
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
                            editorElement docId mode treeMode editable attachments content
                            Html.custom "noscript" [] $
                                Html.button_ [Html.attr "type" "submit"] (Html.text "Save")
                    else editorElement docId mode treeMode editable attachments content

{- | The @\<markdown-editor\>@ custom element with its server-set attributes and the
no-script @\<textarea\>@ fallback holding the document. @data-readonly@ is set in the
read view (RFC-0020); the element disables editing and hides the editing chrome.
-}
editorElement :: String -> Maybe String -> Bool -> Bool -> [(String, String)] -> BS.ByteString -> Html.Html ()
editorElement docId mode treeMode editable attachments content =
    Html.custom
        "markdown-editor"
        ( [Html.attr "name" "markdown", Html.attr "data-document" docId]
            ++ maybe [] (\m -> [Html.attr "mode" m]) mode
            ++ [Html.attr "data-document-mode" "tree" | treeMode]
            ++ [Html.attr "data-attachments" (attachmentsJson attachments) | treeMode, not (null attachments)]
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
