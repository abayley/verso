{-# LANGUAGE OverloadedStrings #-}

module MicroHttp.TestApp (
    DocumentStore (..),
    app,
    appFromConfig,
    appWith,
    appWithDocumentRoot,
    appWithStore,
    documentRoutes,
    fileStore,
    routes,
) where

import qualified Data.ByteString.Char8 as BS
import Data.Char (isSpace)
import Data.List (intercalate)
import MicroHttp.Config (Config, configMounts, configString)
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http as Http
import MicroHttp.Http.Parse (ParseError (..))
import MicroHttp.Http.PercentEncoding (decodeFormValue)
import MicroHttp.Iteratee (liftIO, readBodyStrict)
import MicroHttp.Log (Logger, fileLogfmtLogger)
import MicroHttp.Middleware (logRequests, withErrorResponses)
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import qualified MicroHttp.Static as Static
import MicroHttp.Stream (StreamError (..))
import System.Directory (doesFileExist)

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
                ( documentRoutes
                    (configString "editor_theme" "paper" cfg)
                    (configString "document_root" "data/documents" cfg)
                    ++ [Static.static prefix root | (prefix, root) <- configMounts "static_mounts" cfg]
                )
            )
        )

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
    Router.serveRoutes (Server.parseLimits Server.defaultSettings) (routes "paper" store)

routes :: String -> DocumentStore -> [Router.Route]
routes editorThemeDefault store =
    [ Router.get "/" index
    , Router.get "/index.html" index
    , Router.get "/documents/:id/edit" (editDocument editorThemeDefault store)
    , Router.get "/documents/:id" (showDocument store)
    , Router.post "/documents/:id" (saveDocument editorThemeDefault store)
    , Static.static "/static/editor" "static/editor"
    ]

index :: Router.Handler
index _ _ =
    pure (documentResponse indexPage)

editDocument :: String -> DocumentStore -> Router.Handler
editDocument editorThemeDefault store captures request = do
    let docId = documentId captures
    content <- liftIO (loadDocument store docId)
    pure (documentResponse (editorPage docId (editorMode request) editorThemeDefault content Nothing))

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
                pure (documentResponse (editorPage docId Nothing editorThemeDefault markdown (Just err)))
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
        then readFile path
        else return seededMarkdown

saveFileDocument :: FilePath -> String -> String -> IO ()
saveFileDocument root name =
    writeFile (documentPath root name)

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
editorPage :: String -> Maybe String -> String -> String -> Maybe String -> Html.Html ()
editorPage docId mode themeDefault content maybeError =
    Html.html [Html.lang "en", Html.class_ "wa-theme-default wa-palette-default wa-brand-blue", Html.attr "data-editor-theme" (safeEditorTheme themeDefault)] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.rawTrusted editorThemeBootstrapScript
            Html.title [] "MicroHttp Markdown Editor"
            Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/webawesome.css\">"
            Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
            Html.rawTrusted "<script src=\"https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js\"></script>"
            Html.rawTrusted "<script src=\"/static/editor/markdown-editor.js\"></script>"
        Html.body [Html.class_ "markdown-editor-page"] $ do
            Html.main [] $ do
                Html.form_
                    [ Html.attr "action" ("/documents/" ++ docId)
                    , Html.attr "method" "post"
                    , Html.hxPost ("/documents/" ++ docId)
                    , Html.hxSwap "none"
                    , Html.attr "hx-trigger" "submit, editor:changed delay:2s from:markdown-editor"
                    ]
                    $ do
                        maybe (return ()) validationStatusFragment maybeError
                        Html.custom
                            "markdown-editor"
                            ( [Html.attr "name" "markdown", Html.attr "data-document" docId]
                                ++ maybe [] (\m -> [Html.attr "mode" m]) mode
                            )
                            ( Html.custom
                                "textarea"
                                [Html.attr "name" "markdown", Html.attr "aria-label" "Markdown source", Html.class_ "markdown-editor__fallback"]
                                (Html.text content)
                            )
                        Html.custom "noscript" [] $
                            Html.button_ [Html.attr "type" "submit"] (Html.text "Save")

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
