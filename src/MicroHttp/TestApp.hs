{-# LANGUAGE OverloadedStrings #-}

module MicroHttp.TestApp (
    app,
) where

import qualified Data.ByteString.Char8 as BS
import Data.Char (isDigit)
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server

app :: Server.Application
app =
    Router.route routes

routes :: [Router.Route]
routes =
    [ Router.get "/" index
    , Router.get "/index.html" index
    , Router.get "/documents/:id/edit" editDocument
    , Router.post "/documents/:id" saveDocument
    , Router.get "/static/editor/:file" staticEditorAsset
    ]

index :: Router.Handler
index _ _ =
    return (htmlResponse indexHtml)

editDocument :: Router.Handler
editDocument _ _ =
    return (htmlResponse (documentHtml editorPage))

saveDocument :: Router.Handler
saveDocument _ request =
    return (htmlResponse (Html.renderHtml (saveStatusFragment (markdownValue request))))

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

editorPage :: Html.Html ()
editorPage =
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
                    [ Html.hxPost "/documents/home"
                    , Html.hxTarget "#save-status"
                    , Html.hxSwap "innerHTML"
                    ]
                    $ do
                        Html.custom "markdown-editor" [Html.attr "name" "markdown", Html.attr "mode" "visual"] $
                            Html.text seededMarkdown
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
