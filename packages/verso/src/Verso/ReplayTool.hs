{- | The @replay-tool@ command-line utility (RFC-0028): replay the operation log onto
the document tree, re-imposing the in-server moves and deletes after the corpus has
been refreshed from its authoritative source in the original layout.

Replay is an operator action, not a web action, so it lives here rather than behind
an HTTP route. It reads the same configuration as the server (the @MICROHTTP_CONFIG@
file, default @micro-http.conf@) for @document_tree_root@, @operation_log@, and
@trash_root@, applies each logged operation in order through the shared
'Verso.TreeMove.replayLog' machinery (best-effort: stale operations are skipped),
and prints the report.
-}
module Main (main) where

import qualified Data.Maybe as Maybe
import qualified MicroHttp.Config as Config
import qualified System.Environment as Environment
import qualified System.Exit as Exit
import qualified Verso.Config as VConfig
import qualified Verso.OperationLog as OperationLog
import qualified Verso.TreeMove as TreeMove

-- | The default config path, overridable by @MICROHTTP_CONFIG@ (matching the server).
defaultConfigPath :: FilePath
defaultConfigPath = "micro-http.conf"

-- | Entry point: resolve the config path, load it, and replay (or report a config error).
main :: IO ()
main = do
    configPath <- Maybe.fromMaybe defaultConfigPath <$> Environment.lookupEnv "MICROHTTP_CONFIG"
    loaded <- VConfig.loadConfig configPath
    case loaded of
        Left (Config.ConfigError message) -> do
            putStrLn ("configuration error: " ++ message)
            Exit.exitFailure
        Right cfg -> replay cfg

-- | Replays the configured operation log onto the configured tree, printing the report.
replay :: Config.Config -> IO ()
replay cfg
    | null root = do
        putStrLn "replay-tool: document_tree_root is not set in the configuration"
        Exit.exitFailure
    | otherwise = do
        ops <- OperationLog.readOperations logPath
        putStrLn ("Replaying " ++ show (length ops) ++ " operation(s) from " ++ logPath ++ " onto " ++ root)
        report <- TreeMove.replayLog root trashRoot ops
        mapM_ printEntry report
        let skipped = length (filter (isSkipped . TreeMove.reStatus) report)
        putStrLn ("Done: " ++ show (length report - skipped) ++ " applied, " ++ show skipped ++ " skipped")
  where
    root = Config.configString "document_tree_root" "" cfg
    logPath = Config.configString "operation_log" "data/operation_log" cfg
    trashRoot = Config.configString "trash_root" "data/trash" cfg

-- | Prints one replayed operation's outcome.
printEntry :: TreeMove.ReplayEntry -> IO ()
printEntry entry =
    putStrLn ("  seq " ++ show (TreeMove.reSeq entry) ++ " " ++ TreeMove.reType entry ++ ": " ++ TreeMove.reStatus entry)

-- | Whether a replay status line reports a skip (as opposed to @applied@).
isSkipped :: String -> Bool
isSkipped status = take (length prefix) status == prefix
  where
    prefix = "skipped"
