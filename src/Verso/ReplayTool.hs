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

import Data.Maybe (fromMaybe)
import MicroHttp.Config (Config, ConfigError (..), configString)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import Verso.Config (loadConfig)
import Verso.OperationLog (readOperations)
import Verso.TreeMove (ReplayEntry (..), replayLog)

-- | The default config path, overridable by @MICROHTTP_CONFIG@ (matching the server).
defaultConfigPath :: FilePath
defaultConfigPath = "micro-http.conf"

main :: IO ()
main = do
    configPath <- fromMaybe defaultConfigPath <$> lookupEnv "MICROHTTP_CONFIG"
    loaded <- loadConfig configPath
    case loaded of
        Left (ConfigError message) -> do
            putStrLn ("configuration error: " ++ message)
            exitFailure
        Right cfg -> replay cfg

-- | Replays the configured operation log onto the configured tree, printing the report.
replay :: Config -> IO ()
replay cfg
    | null root = do
        putStrLn "replay-tool: document_tree_root is not set in the configuration"
        exitFailure
    | otherwise = do
        ops <- readOperations logPath
        putStrLn ("Replaying " ++ show (length ops) ++ " operation(s) from " ++ logPath ++ " onto " ++ root)
        report <- replayLog root trashRoot ops
        mapM_ printEntry report
        let skipped = length (filter (isSkipped . reStatus) report)
        putStrLn ("Done: " ++ show (length report - skipped) ++ " applied, " ++ show skipped ++ " skipped")
  where
    root = configString "document_tree_root" "" cfg
    logPath = configString "operation_log" "data/operation_log" cfg
    trashRoot = configString "trash_root" "data/trash" cfg

-- | Prints one replayed operation's outcome.
printEntry :: ReplayEntry -> IO ()
printEntry entry =
    putStrLn ("  seq " ++ show (reSeq entry) ++ " " ++ reType entry ++ ": " ++ reStatus entry)

-- | Whether a replay status line reports a skip (as opposed to @applied@).
isSkipped :: String -> Bool
isSkipped status = take (length prefix) status == prefix
  where
    prefix = "skipped"
