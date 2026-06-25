module Main (main) where

import Data.Maybe (fromMaybe)
import MicroHttp.Config (Config, ConfigError (..), loadConfig, toSettings)
import MicroHttp.Network.Socket (Host (..), Port (..))
import qualified MicroHttp.Server as Server
import qualified MicroHttp.TestApp as TestApp
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)

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
            -- Build the application (which warms the link index, RFC-0029) before
            -- announcing the listen address, so "listening on" appears once the server
            -- is actually about to accept connections, after the index is ready.
            application <- TestApp.appFromConfig settings cfg
            putStrLn ("listening on " ++ listenAddress settings)
            hFlush stdout
            result <- Server.serve settings application
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

-- | The configured listen address as @<ip>:<port>@; the any-host binds 0.0.0.0.
listenAddress :: Server.Settings -> String
listenAddress settings =
    renderHost (Server.settingsHost settings) ++ ":" ++ renderPort (Server.settingsPort settings)
  where
    renderHost HostAny = "0.0.0.0"
    renderHost (HostIPv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
    renderPort (Port p) = show p
