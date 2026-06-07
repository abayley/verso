{-# LANGUAGE OverloadedStrings #-}

module MicroHttp.TestApp (
    DocumentStore (..),
    app,
    appWithDocumentRoot,
    appWithStore,
) where

import qualified Data.ByteString.Char8 as BS
import Data.Char (isDigit, isSpace)
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server
import System.Directory (doesFileExist)

data DocumentStore = DocumentStore
    { loadDocument :: String -> IO String
    , saveDocumentContent :: String -> String -> IO ()
    }

app :: Server.Application
app =
    appWithDocumentRoot "data/documents"

appWithDocumentRoot :: FilePath -> Server.Application
appWithDocumentRoot root =
    appWithStore
        DocumentStore
            { loadDocument = loadFileDocument root
            , saveDocumentContent = saveFileDocument root
            }

appWithStore :: DocumentStore -> Server.Application
appWithStore store =
    Router.route (routes store)

routes :: DocumentStore -> [Router.Route]
routes store =
    [ Router.get "/" index
    , Router.get "/index.html" index
    , Router.get "/documents/:id/edit" (editDocument store)
    , Router.get "/documents/:id" (showDocument store)
    , Router.post "/documents/:id/preview" previewDocument
    , Router.post "/documents/:id" (saveDocument store)
    , Router.get "/static/editor/:file" staticEditorAsset
    ]

index :: Router.Handler
index _ _ =
    return (htmlResponse indexHtml)

editDocument :: DocumentStore -> Router.Handler
editDocument store captures request = do
    let docId = documentId captures
    markdown <- loadDocument store docId
    return (htmlResponse (documentHtml (editorPage docId (editorMode request) markdown)))

showDocument :: DocumentStore -> Router.Handler
showDocument store captures _ = do
    markdown <- loadDocument store (documentId captures)
    return (htmlResponse (documentHtml (documentPage markdown)))

saveDocument :: DocumentStore -> Router.Handler
saveDocument store captures request = do
    let markdown = markdownValue request
    case validateMarkdown markdown of
        Just err -> return (htmlResponse (Html.renderHtml (validationStatusFragment err)))
        Nothing -> do
            saveDocumentContent store (documentId captures) markdown
            return (htmlResponse (Html.renderHtml (saveStatusFragment markdown)))

previewDocument :: Router.Handler
previewDocument _ request =
    let markdown = markdownValue request
     in case validateMarkdown markdown of
            Just err -> return (htmlResponse (Html.renderHtml (validationStatusFragment err)))
            Nothing -> return (htmlResponse (Html.renderHtml (previewFragment markdown)))

staticEditorAsset :: Router.Handler
staticEditorAsset captures _ =
    case capture "file" captures of
        "markdown-editor.js" -> return (fileResponse "text/javascript" "static/editor/markdown-editor.js")
        "markdown-editor.css" -> return (fileResponse "text/css" "static/editor/markdown-editor.css")
        _ -> return notFoundResponse

htmlResponse :: String -> Http.Response
htmlResponse body =
    Http.Response
        Http.okStatus
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/html")]
        (Http.StrictBody (BS.pack body))

fileResponse :: String -> FilePath -> Http.Response
fileResponse contentType path =
    Http.Response
        Http.okStatus
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack contentType)]
        (Http.FileBody path)

notFoundResponse :: Http.Response
notFoundResponse =
    Http.Response
        (Http.Status 404 "Not Found")
        [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/plain")]
        (Http.StrictBody (BS.pack "not found\n"))

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

queryValue :: String -> Http.Request -> String
queryValue name request =
    capture name (Http.requestQuery request)

editorMode :: Http.Request -> String
editorMode request =
    case queryValue "mode" request of
        "source" -> "source"
        _ -> "visual"

markdownValue :: Http.Request -> String
markdownValue request =
    capture "markdown" (formFields (BS.unpack (Http.requestBody request)))

formFields :: String -> [(String, String)]
formFields "" = []
formFields body =
    map parseField (splitOn '&' body)

parseField :: String -> (String, String)
parseField field =
    case break (== '=') field of
        (key, '=' : value) -> (percentDecode key, percentDecode value)
        (key, _) -> (percentDecode key, "")

splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]

percentDecode :: String -> String
percentDecode [] = []
percentDecode ('%' : a : b : rest) =
    case hexPair a b of
        Just c -> c : percentDecode rest
        Nothing -> '%' : a : b : percentDecode rest
percentDecode ('+' : rest) = ' ' : percentDecode rest
percentDecode (c : rest) = c : percentDecode rest

hexPair :: Char -> Char -> Maybe Char
hexPair a b =
    case (hexValue a, hexValue b) of
        (Just high, Just low) -> Just (toEnum (high * 16 + low))
        _ -> Nothing

hexValue :: Char -> Maybe Int
hexValue c
    | isDigit c = Just (fromEnum c - fromEnum '0')
    | 'a' <= c && c <= 'f' = Just (10 + fromEnum c - fromEnum 'a')
    | 'A' <= c && c <= 'F' = Just (10 + fromEnum c - fromEnum 'A')
    | otherwise = Nothing

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

documentPage :: String -> Html.Html ()
documentPage markdown =
    Html.html [Html.lang "en"] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.title [] "MicroHttp Markdown Document"
        Html.body [] $ do
            Html.main [] $
                renderMarkdownHtml markdown

editorPage :: String -> String -> String -> Html.Html ()
editorPage docId mode markdown =
    Html.html [Html.lang "en"] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.title [] "MicroHttp Markdown Editor"
            Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
            Html.rawTrusted "<script src=\"https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js\"></script>"
            Html.rawTrusted "<script src=\"/static/editor/markdown-editor.js\"></script>"
        Html.body [] $ do
            Html.main [] $ do
                Html.h1 [] "Markdown Editor"
                Html.form_
                    [ Html.hxPost ("/documents/" ++ docId)
                    , Html.hxTarget "#save-status"
                    , Html.hxSwap "innerHTML"
                    ]
                    $ do
                        Html.custom "markdown-editor" [Html.attr "name" "markdown", Html.attr "mode" mode] $
                            Html.text markdown
                        Html.input [Html.attr "type" "hidden", Html.attr "name" "markdown", Html.attr "id" "markdown-field"]
                        Html.button [Html.attr "type" "submit"] "Save"
                Html.div [Html.attr "id" "save-status"] ""

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

previewFragment :: String -> Html.Html ()
previewFragment markdown =
    Html.div [Html.attr "id" "preview"] $
        renderMarkdownHtml markdown

renderMarkdownHtml :: String -> Html.Html ()
renderMarkdownHtml markdown =
    mapM_ renderMarkdownBlock (paragraphBlocks markdown)

renderMarkdownBlock :: String -> Html.Html ()
renderMarkdownBlock block
    | isUnorderedListBlock block = renderUnorderedList block
    | isOrderedListBlock block = renderOrderedList block
    | otherwise =
        case headingLevel block of
            Just 1 -> Html.h1 [] (renderInlineMarkdown (headingText 2 block))
            Just 2 -> Html.h2 [] (renderInlineMarkdown (headingText 3 block))
            Just 3 -> Html.h3 [] (renderInlineMarkdown (headingText 4 block))
            _ -> Html.p [] (renderInlineMarkdown block)

renderUnorderedList :: String -> Html.Html ()
renderUnorderedList block =
    Html.ul [] $
        mapM_ renderUnorderedListItem (lines block)

renderUnorderedListItem :: String -> Html.Html ()
renderUnorderedListItem row =
    Html.li [] (renderInlineMarkdown (drop 2 (trimStart row)))

renderOrderedList :: String -> Html.Html ()
renderOrderedList block =
    Html.ol [] $
        mapM_ renderOrderedListItem (lines block)

renderOrderedListItem :: String -> Html.Html ()
renderOrderedListItem row =
    Html.li [] (renderInlineMarkdown (orderedListItemText row))

renderInlineMarkdown :: String -> Html.Html ()
renderInlineMarkdown [] = return ()
renderInlineMarkdown text
    | hasPrefix "**" text =
        case breakOn "**" (drop 2 text) of
            Just (strongText, rest) -> do
                Html.el "strong" [] (renderInlineMarkdown strongText)
                renderInlineMarkdown rest
            Nothing -> renderTextChar text
    | hasPrefix "*" text =
        case breakOn "*" (drop 1 text) of
            Just (emText, rest) -> do
                Html.el "em" [] (renderInlineMarkdown emText)
                renderInlineMarkdown rest
            Nothing -> renderTextChar text
    | hasPrefix "`" text =
        case breakOn "`" (drop 1 text) of
            Just (codeText, rest) -> do
                Html.el "code" [] (Html.text codeText)
                renderInlineMarkdown rest
            Nothing -> renderTextChar text
    | hasPrefix "[" text =
        case linkParts (drop 1 text) of
            Just (label, url, rest) -> do
                Html.a [Html.href url] (renderInlineMarkdown label)
                renderInlineMarkdown rest
            Nothing -> renderTextChar text
    | otherwise = renderTextChar text

renderTextChar :: String -> Html.Html ()
renderTextChar [] = return ()
renderTextChar (c : rest) = do
    Html.text [c]
    renderInlineMarkdown rest

linkParts :: String -> Maybe (String, String, String)
linkParts text =
    case breakOn "](" text of
        Just (label, urlAndRest) ->
            case breakOn ")" urlAndRest of
                Just (url, rest) -> Just (label, url, rest)
                Nothing -> Nothing
        Nothing -> Nothing

breakOn :: String -> String -> Maybe (String, String)
breakOn needle =
    breakOnFrom ""
  where
    breakOnFrom seen rest
        | hasPrefix needle rest = Just (reverse seen, drop (length needle) rest)
        | otherwise =
            case rest of
                [] -> Nothing
                c : more -> breakOnFrom (c : seen) more

hasPrefix :: String -> String -> Bool
hasPrefix [] _ = True
hasPrefix _ [] = False
hasPrefix (expected : expectedRest) (actual : actualRest)
    | expected == actual = hasPrefix expectedRest actualRest
    | otherwise = False

headingLevel :: String -> Maybe Int
headingLevel ('#' : ' ' : _) = Just 1
headingLevel ('#' : '#' : ' ' : _) = Just 2
headingLevel ('#' : '#' : '#' : ' ' : _) = Just 3
headingLevel _ = Nothing

headingText :: Int -> String -> String
headingText =
    drop

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
    isHeading block || isUnorderedListBlock block || isOrderedListBlock block || isParagraph block

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
