module Main (main) where

import qualified MicroHttp.Server as Server
import qualified MicroHttp.TestApp as TestApp

-- | Run the test application on port 8080.
main :: IO ()
main = do
    putStrLn "listening on http://127.0.0.1:8080/"
    result <- Server.serve Server.defaultSettings TestApp.app
    case result of
        Left err -> putStrLn ("server failed: " ++ show err)
        Right () -> return ()
