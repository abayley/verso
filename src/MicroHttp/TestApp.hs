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
import Data.Char (isDigit, isSpace)
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
    , Router.get "/documents/:id/edit" (editDocument editorThemeDefault)
    , Router.get "/documents/:id" (showDocument store)
    , Router.post "/documents/:id" (saveDocument store)
    , Static.static "/static/editor" "static/editor"
    ]

index :: Router.Handler
index _ _ =
    pure (htmlResponse indexHtml)

editDocument :: String -> Router.Handler
editDocument editorThemeDefault captures request =
    let docId = documentId captures
     in pure (htmlResponse (documentHtml (editorPage docId (editorMode request) editorThemeDefault)))

showDocument :: DocumentStore -> Router.Handler
showDocument store captures _ = do
    markdown <- liftIO (loadDocument store (documentId captures))
    pure (markdownResponse markdown)

saveDocument :: DocumentStore -> Router.Handler
saveDocument store captures _ = do
    bodyBytes <- readBodyStrict (StreamParseError BodyTooLarge) formBodyLimit
    let markdown = markdownFromBody bodyBytes
    case validateMarkdown markdown of
        Just err -> pure (htmlResponse (Html.renderHtml (validationStatusFragment err)))
        Nothing -> do
            liftIO (saveDocumentContent store (documentId captures) markdown)
            pure (htmlResponse (Html.renderHtml (saveStatusFragment markdown)))

-- | The handler's own body bound; the server pipeline also caps the body.
formBodyLimit :: Int
formBodyLimit = 1048576

htmlResponse :: String -> Http.Response
htmlResponse body =
    Http.Response
        Http.okStatus
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/html")]
        (Http.StrictBody (BS.pack body))

markdownResponse :: String -> Http.Response
markdownResponse body =
    Http.Response
        Http.okStatus
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/markdown")]
        (Http.StrictBody (BS.pack body))

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

editorMode :: Http.RequestHead -> String
editorMode request =
    case queryValue "mode" request of
        "source" -> "source"
        "split" -> "split"
        _ -> "visual"

markdownFromBody :: BS.ByteString -> String
markdownFromBody bytes =
    capture "markdown" (formFields (BS.unpack bytes))

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

indexHtml :: String
indexHtml =
    documentHtml indexPage

documentHtml :: Html.Html () -> String
documentHtml page =
    "<!doctype html>" ++ Html.renderHtml page

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
knownEditorThemes = ["paper", "aurora"]

-- | Validates a configured default theme name, falling back to @paper@.
safeEditorTheme :: String -> String
safeEditorTheme theme
    | theme `elem` knownEditorThemes = theme
    | otherwise = "paper"

{- | An inline, pre-paint script that applies the visitor's stored editor
preferences before the body renders, so a saved theme or colour scheme does not
flash the page default. It sets the theme attribute only from a fixed allowlist,
so a tampered stored value cannot inject an attribute payload.
-}
editorThemeBootstrapScript :: String
editorThemeBootstrapScript =
    "<script>(function(){try{"
        ++ "var K=['paper','aurora'];var r=document.documentElement;"
        ++ "var t=localStorage.getItem('editor-theme');"
        ++ "if(t&&K.indexOf(t)>=0){r.setAttribute('data-editor-theme',t);}"
        ++ "var s=localStorage.getItem('editor-color-scheme');"
        ++ "if(s==='dark'){r.classList.add('wa-dark');}else if(s==='light'){r.classList.add('wa-light');}"
        ++ "}catch(e){}})();</script>"

editorPage :: String -> String -> String -> Html.Html ()
editorPage docId mode themeDefault =
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
                    [ Html.hxPost ("/documents/" ++ docId)
                    , Html.hxSwap "none"
                    , Html.attr "hx-trigger" "submit, editor:changed delay:2s from:markdown-editor"
                    ]
                    $ do
                        Html.custom
                            "markdown-editor"
                            [ Html.attr "name" "markdown"
                            , Html.attr "mode" mode
                            , Html.attr "src" ("/documents/" ++ docId)
                            ]
                            (return ())
                        Html.input [Html.attr "type" "hidden", Html.attr "name" "markdown", Html.attr "id" "markdown-field"]

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

validateMarkdown :: String -> Maybe String
validateMarkdown markdown
    | containsRawHtml markdown = Just "raw HTML is not supported in this spike."
    | otherwise = validateBlocks (paragraphBlocks markdown)

containsRawHtml :: String -> Bool
containsRawHtml [] = False
containsRawHtml ('<' : _) = True
containsRawHtml (_ : rest) = containsRawHtml rest

paragraphBlocks :: String -> [String]
paragraphBlocks markdown =
    filter (not . null) (map trim (splitParagraphs (lines markdown)))

splitParagraphs :: [String] -> [String]
splitParagraphs [] = []
splitParagraphs rows =
    case break (all isSpace) rows of
        (before, _ : after) -> unlinesNoTrailing before : splitParagraphs after
        (before, []) -> [unlinesNoTrailing before]

unlinesNoTrailing :: [String] -> String
unlinesNoTrailing [] = ""
unlinesNoTrailing [row] = row
unlinesNoTrailing (row : rows) = row ++ "\n" ++ unlinesNoTrailing rows

validateBlocks :: [String] -> Maybe String
validateBlocks [] = Nothing
validateBlocks (block : rest)
    | supportedBlock block = validateBlocks rest
    | otherwise = Just "unsupported block syntax."

supportedBlock :: String -> Bool
supportedBlock block =
    isHeading block || isUnorderedListBlock block || isOrderedListBlock block || isFencedCodeBlock block || isBlockquoteBlock block || isParagraph block

isHeading :: String -> Bool
isHeading ('#' : ' ' : rest) = not (null (trim rest))
isHeading ('#' : '#' : ' ' : rest) = not (null (trim rest))
isHeading ('#' : '#' : '#' : ' ' : rest) = not (null (trim rest))
isHeading ('#' : _) = False
isHeading _ = False

isParagraph :: String -> Bool
isParagraph block =
    not (startsUnsupportedBlock block)

startsUnsupportedBlock :: String -> Bool
startsUnsupportedBlock block =
    case trimStart block of
        '>' : _ -> True
        '`' : '`' : '`' : _ -> True
        _ -> False

isFencedCodeBlock :: String -> Bool
isFencedCodeBlock block =
    case lines block of
        opening : body -> isCodeFenceOpening opening && hasClosingCodeFence body
        [] -> False

isCodeFenceOpening :: String -> Bool
isCodeFenceOpening row =
    case trimStart row of
        '`' : '`' : '`' : _ -> True
        _ -> False

hasClosingCodeFence :: [String] -> Bool
hasClosingCodeFence [] = False
hasClosingCodeFence [row] = isCodeFenceClosing row
hasClosingCodeFence (_ : rows) = hasClosingCodeFence rows

isCodeFenceClosing :: String -> Bool
isCodeFenceClosing row =
    trim row == "```"

isBlockquoteBlock :: String -> Bool
isBlockquoteBlock block =
    all isBlockquoteLine (lines block)

isBlockquoteLine :: String -> Bool
isBlockquoteLine row =
    case trimStart row of
        '>' : rest | all isSpace rest -> True
        '>' : ' ' : rest -> not (null (trim rest))
        _ -> False

isUnorderedListBlock :: String -> Bool
isUnorderedListBlock block =
    all isUnorderedListItem (lines block)

isUnorderedListItem :: String -> Bool
isUnorderedListItem row =
    case trimStart row of
        '-' : ' ' : rest -> not (null (trim rest))
        '*' : ' ' : rest -> not (null (trim rest))
        '+' : ' ' : rest -> not (null (trim rest))
        _ -> False

startsOrderedList :: String -> Bool
startsOrderedList block =
    case span isDigit (trimStart block) of
        ("", _) -> False
        (_, '.' : ' ' : _) -> True
        _ -> False

isOrderedListBlock :: String -> Bool
isOrderedListBlock block =
    all isOrderedListItem (lines block)

isOrderedListItem :: String -> Bool
isOrderedListItem row =
    case span isDigit (trimStart row) of
        ("", _) -> False
        (_, '.' : ' ' : rest) -> not (null (trim rest))
        _ -> False

orderedListItemText :: String -> String
orderedListItemText row =
    case span isDigit (trimStart row) of
        (_, '.' : ' ' : rest) -> rest
        _ -> trimStart row

trim :: String -> String
trim =
    reverse . trimStart . reverse . trimStart

trimStart :: String -> String
trimStart =
    dropWhile isSpace
