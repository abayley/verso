module Main (main) where

import MicroHttp.Log (fileLogfmtLogger)
import qualified MicroHttp.Server as Server
import qualified MicroHttp.TestApp as TestApp

{- | The access-log file location. A constant until configuration lands
(RFC-0011); the logger itself is the injected component from RFC-0009.
-}
accessLogPath :: FilePath
accessLogPath = "build/access.log"

-- | Run the test application on port 8080, writing an access log.
main :: IO ()
main = do
    putStrLn "listening on http://127.0.0.1:8080/"
    putStrLn ("access log: " ++ accessLogPath)
    let settings = Server.defaultSettings{Server.settingsLogger = fileLogfmtLogger accessLogPath}
    result <- Server.serve settings TestApp.app
    case result of
        Left err -> putStrLn ("server failed: " ++ show err)
        Right () -> return ()
