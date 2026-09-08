module Main (main) where

import qualified Control.Monad as Monad
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Config as Config
import qualified MicroHttp.Log as Log
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Server as Server
import qualified System.Environment as Environment
import qualified System.Exit as Exit
import qualified System.IO as IO
import qualified System.IO.TimeMilli as TimeMilli
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
    startedAt <- TimeMilli.getTimeMilli
    Log.consoleLog "MicroHTTP startup"
    configPath <- Maybe.fromMaybe defaultConfigPath <$> Environment.lookupEnv "MICROHTTP_CONFIG"
    loaded <- Log.timed "startup: config" (VConfig.loadConfig configPath)
    case loaded >>= prepare of
        Left err -> failWith err
        Right (settings, versoCfg) -> do
            warnIfShadowed settings
            -- Build the application (which warms the link index, RFC-0029) before
            -- announcing the listen address, so "listening on" appears once the server
            -- is actually about to accept connections, after the index is ready. The
            -- announcement itself is made from the ready callback, once the socket is
            -- bound: printed before, it claimed success and was then followed by a bind
            -- failure.
            application <- App.appFromConfig settings versoCfg
            result <- Server.serveWithReady settings (announce startedAt settings) application
            case result of
                Left err -> do
                    Log.consoleLog ("failed to listen on " ++ listenAddress settings ++ ": " ++ show err)
                    Exit.exitFailure
                Right () -> return ()

{- | Reports the address the bound socket is accepting on, and how long getting here took.

The total is the one number worth watching: the per-phase lines say which phase to blame
when it grows.
-}
announce :: Int -> Server.Settings -> Socket.Port -> IO ()
announce startedAt settings port = do
    readyAt <- TimeMilli.getTimeMilli
    Log.consoleLog ("startup: total " ++ show (readyAt - startedAt) ++ "ms")
    -- With the scheme, so the terminal makes it a link worth clicking.
    Log.consoleLog
        ("listening on http://" ++ renderHost (Server.settingsHost settings) ++ ":" ++ renderPort port)

{- | Warns when another process already answers on the loopback address of the configured
port, which a wildcard bind does not report.

With @host = 0.0.0.0@ the bind still succeeds while a listener on 127.0.0.1 keeps the
loopback traffic, because the more specific bind wins: the server starts, says it is
listening, and nothing ever reaches it through @localhost@. The default host is loopback,
where this is an outright bind failure instead, so the warning is for the wildcard case.
-}
warnIfShadowed :: Server.Settings -> IO ()
warnIfShadowed settings =
    case Server.settingsHost settings of
        Socket.HostAny -> do
            let port = Server.settingsPort settings
            busy <- Socket.probeListener (Socket.HostIPv4 127 0 0 1) port
            Monad.when busy $
                Log.consoleLog
                    ( "warning: 127.0.0.1:"
                        ++ renderPort port
                        ++ " is already served by another process; this server binds the wildcard, so"
                        ++ " http://localhost:"
                        ++ renderPort port
                        ++ "/ will reach that one, not this"
                    )
        _ -> return ()

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

-- | A host as dotted-quad text; the any-host renders as the wildcard it binds.
renderHost :: Socket.Host -> String
renderHost Socket.HostAny = "0.0.0.0"
renderHost (Socket.HostIPv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

-- | A port as decimal text.
renderPort :: Socket.Port -> String
renderPort (Socket.Port p) = show p
