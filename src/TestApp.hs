{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Server as Server

-- | Run the sequential test application on port 8080.
main :: IO ()
main = do
    putStrLn "listening on http://127.0.0.1:8080/"
    serveLoop

-- | Serve one request at a time so blocking socket FFI cannot starve handlers.
serveLoop :: IO ()
serveLoop = do
    result <- Server.serveOne Server.defaultSettings app
    case result of
        Left err -> putStrLn ("server failed: " ++ show err)
        Right () -> serveLoop

-- | Route incoming requests for the test application.
app :: Server.Application
app =
    Router.route routes

-- | Routes exposed by the test application.
routes :: [Router.Route]
routes =
    [ Router.get "/" index
    , Router.get "/index.html" index
    ]

-- | Render the index page response.
index :: Router.Handler
index _ _ =
    return
        ( Http.Response
            Http.okStatus
            [(Http.normaliseHeaderName (BS.pack "Content-Type"), BS.pack "text/html")]
            (Http.StrictBody (BS.pack indexHtml))
        )

-- | Complete index document.
indexHtml :: String
indexHtml =
    "<!doctype html>"
        ++ Html.renderHtml page

-- | Basic HTML document rendered by MicroHttp's HTML combinators.
page :: Html.Html ()
page = do
    Html.html [Html.lang "en"] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.title [] "MicroHttp Test App"
        Html.body [] $ do
            Html.main [] $ do
                Html.h1 [] "MicroHttp"
                Html.p [] "The MicroHs HTTP server is running."
                Html.custom "status-card" [Html.attr "data-state" "ok"] "Served by src/TestApp.hs"
