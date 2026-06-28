module Main (main) where

import qualified Data.Maybe as Maybe
import qualified MicroHttp.Config as Config
import qualified MicroHttp.Log as Log
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Server as Server
import qualified System.Environment as Environment
import qualified System.Exit as Exit
import qualified System.IO as IO
import qualified Verso.App as App
import qualified Verso.Config as VConfig

{- | The default config file path, overridable by the @MICROHTTP_CONFIG@
environment variable. A missing file means built-in defaults (RFC-0011).
-}
defaultConfigPath :: FilePath
defaultConfigPath = "micro-http.conf"

-- | Start the server: load config, build the application, then serve.
main :: IO ()
main = do
    Log.consoleLog "MicroHTTP startup"
    configPath <- Maybe.fromMaybe defaultConfigPath <$> Environment.lookupEnv "MICROHTTP_CONFIG"
    loaded <- VConfig.loadConfig configPath
    case loaded >>= prepare of
        Left err -> failWith err
        Right (settings, versoCfg) -> do
            -- Build the application (which warms the link index, RFC-0029) before
            -- announcing the listen address, so "listening on" appears once the server
            -- is actually about to accept connections, after the index is ready.
            application <- App.appFromConfig settings versoCfg
            Log.consoleLog ("listening on " ++ listenAddress settings)
            result <- Server.serve settings application
            case result of
                Left err -> Log.consoleLog ("server failed: " ++ show err)
                Right () -> return ()

{- | The framework settings and the application config, both mapped from the
loaded config and failing fast on a bad value.
-}
prepare :: Config.Config -> Either Config.ConfigError (Server.Settings, VConfig.VersoConfig)
prepare cfg = do
    settings <- Config.toSettings cfg
    versoCfg <- VConfig.fromConfig cfg
    pure (settings, versoCfg)

-- | Report a configuration error to the console and exit with failure.
failWith :: Config.ConfigError -> IO ()
failWith (Config.ConfigError message) = do
    Log.consoleLog ("configuration error: " ++ message)
    Exit.exitFailure

-- | The configured listen address as @<ip>:<port>@; the any-host binds 0.0.0.0.
listenAddress :: Server.Settings -> String
listenAddress settings =
    renderHost (Server.settingsHost settings) ++ ":" ++ renderPort (Server.settingsPort settings)
  where
    renderHost Socket.HostAny = "0.0.0.0"
    renderHost (Socket.HostIPv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
    renderPort (Socket.Port p) = show p
