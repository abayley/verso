module Main (main) where

import Data.Maybe (fromMaybe)
import MicroHttp.Config (Config, ConfigError (..), toSettings)
import MicroHttp.Log (consoleLog)
import MicroHttp.Network.Socket (Host (..), Port (..))
import qualified MicroHttp.Server as Server
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)
import qualified Verso.App as App
import Verso.Config (VersoConfig, fromConfig, loadConfig)

{- | The default config file path, overridable by the @MICROHTTP_CONFIG@
environment variable. A missing file means built-in defaults (RFC-0011).
-}
defaultConfigPath :: FilePath
defaultConfigPath = "micro-http.conf"

main :: IO ()
main = do
    consoleLog "MicroHTTP startup"
    configPath <- fromMaybe defaultConfigPath <$> lookupEnv "MICROHTTP_CONFIG"
    loaded <- loadConfig configPath
    case loaded >>= prepare of
        Left err -> failWith err
        Right (settings, versoCfg) -> do
            -- Build the application (which warms the link index, RFC-0029) before
            -- announcing the listen address, so "listening on" appears once the server
            -- is actually about to accept connections, after the index is ready.
            application <- App.appFromConfig settings versoCfg
            consoleLog ("listening on " ++ listenAddress settings)
            result <- Server.serve settings application
            case result of
                Left err -> consoleLog ("server failed: " ++ show err)
                Right () -> return ()

{- | The framework settings and the application config, both mapped from the
loaded config and failing fast on a bad value.
-}
prepare :: Config -> Either ConfigError (Server.Settings, VersoConfig)
prepare cfg = do
    settings <- toSettings cfg
    versoCfg <- fromConfig cfg
    pure (settings, versoCfg)

failWith :: ConfigError -> IO ()
failWith (ConfigError message) = do
    consoleLog ("configuration error: " ++ message)
    exitFailure

-- | The configured listen address as @<ip>:<port>@; the any-host binds 0.0.0.0.
listenAddress :: Server.Settings -> String
listenAddress settings =
    renderHost (Server.settingsHost settings) ++ ":" ++ renderPort (Server.settingsPort settings)
  where
    renderHost HostAny = "0.0.0.0"
    renderHost (HostIPv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
    renderPort (Port p) = show p
