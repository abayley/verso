module Main (main) where

import Data.Maybe (fromMaybe)
import MicroHttp.Config (Config, ConfigError (..), loadConfig, toSettings)
import qualified MicroHttp.Server as Server
import qualified MicroHttp.TestApp as TestApp
import System.Environment (lookupEnv)
import System.Exit (exitFailure)

{- | The default config file path, overridable by the @MICROHTTP_CONFIG@
environment variable. A missing file means built-in defaults (RFC-0011).
-}
defaultConfigPath :: FilePath
defaultConfigPath = "micro-http.conf"

main :: IO ()
main = do
    configPath <- fromMaybe defaultConfigPath <$> lookupEnv "MICROHTTP_CONFIG"
    loaded <- loadConfig configPath
    case loaded >>= withSettings of
        Left err -> failWith err
        Right (settings, cfg) -> do
            putStrLn "MicroHttp server starting"
            result <- Server.serve settings (TestApp.appFromConfig settings cfg)
            case result of
                Left err -> putStrLn ("server failed: " ++ show err)
                Right () -> return ()

-- | Pairs the config with the settings it maps to, failing on a bad value.
withSettings :: Config -> Either ConfigError (Server.Settings, Config)
withSettings cfg =
    case toSettings cfg of
        Left err -> Left err
        Right settings -> Right (settings, cfg)

failWith :: ConfigError -> IO ()
failWith (ConfigError message) = do
    putStrLn ("configuration error: " ++ message)
    exitFailure
