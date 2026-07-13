{- | The Verso application's configuration (RFC-0030). The framework
('MicroHttp.Config') provides the generic parser, typed lookups, and the
prefix-scoped environment overlay; this module owns the application's keys: it
lists them ('appEnvKeys') so the @VERSO_@ environment overlay is scoped to them,
reads them into a typed 'VersoConfig' record ('fromConfig'), and orchestrates the
load ('loadConfig') by layering the framework's @MICROHTTP_@ / 'serverEnvKeys'
overlay and the application's @VERSO_@ / 'appEnvKeys' overlay over the same file.

The two overlays own disjoint key sets, so a @MICROHTTP_@ variable never reaches
an application key and a @VERSO_@ variable never reaches a server key.
-}
module Verso.Config (
    VersoConfig (..),
    fromConfig,
    appEnvKeys,
    loadConfig,
) where

import qualified MicroHttp.Config as Config

-- | The application's resolved configuration, read once from a 'Config.Config'.
data VersoConfig = VersoConfig
    { documentTreeRoot :: String
    , editorTheme :: String
    , operationLog :: String
    , trashRoot :: String
    , trashRetentionDays :: Int
    , linkIndex :: String
    , accessLog :: String
    , clientErrorLog :: String
    , logMaxBytes :: Int
    , logKeep :: Int
    , staticMounts :: [(String, String)]
    , versioningEnabled :: Bool
    , linkIndexEnabled :: Bool
    , draftRoot :: String
    , identityHeader :: String
    , identityDefault :: String
    , identityEmailDomain :: String
    , searchEnabled :: Bool
    , searchModel :: String
    , searchVocab :: String
    , searchIndexDir :: String
    , searchModelId :: String
    , searchPooling :: String
    , searchMaxTokens :: Int
    , searchDims :: Int
    , searchThreads :: Int
    , searchQueryPrefix :: String
    }
    deriving (Eq, Show)

{- | The application keys, owned by the @VERSO_@ environment overlay. Listed here
so the overlay can be scoped to exactly these keys (RFC-0030).
-}
appEnvKeys :: [String]
appEnvKeys =
    [ "document_tree_root"
    , "editor_theme"
    , "operation_log"
    , "trash_root"
    , "trash_retention_days"
    , "link_index"
    , "access_log"
    , "client_error_log"
    , "log_max_bytes"
    , "log_keep"
    , "static_mounts"
    , "versioning_enabled"
    , "link_index_enabled"
    , "draft_root"
    , "identity_header"
    , "identity_default"
    , "identity_email_domain"
    , "search_enabled"
    , "search_model"
    , "search_vocab"
    , "search_index"
    , "search_model_id"
    , "search_pooling"
    , "search_max_tokens"
    , "search_dims"
    , "search_threads"
    , "search_query_prefix"
    ]

-- | The default trash retention in days (zero or negative disables the sweep).
defaultTrashRetentionDays :: Int
defaultTrashRetentionDays = 90

-- | The default log-rotation threshold in bytes (10 MiB) and retained-file count (RFC-0024).
defaultLogMaxBytes :: Int
defaultLogMaxBytes = 10485760

-- | The default count of rotated log files to retain (RFC-0024).
defaultLogKeep :: Int
defaultLogKeep = 5

{- | Reads the application's keys into a 'VersoConfig', failing fast on a
malformed integer (matching 'MicroHttp.Config.toSettings' for server keys) or
a missing @document_tree_root@ -- the document tree is the only serving mode
(RFC-0036 retired the flat store), so a config without it is an error, not a
fallback. Other absent keys take their built-in defaults.
-}
fromConfig :: Config.Config -> Either Config.ConfigError VersoConfig
fromConfig cfg = do
    maxBytes <- Config.configInt "log_max_bytes" defaultLogMaxBytes cfg
    keep <- Config.configInt "log_keep" defaultLogKeep cfg
    versioning <- Config.configBool "versioning_enabled" True cfg
    indexEnabled <- Config.configBool "link_index_enabled" True cfg
    searchOn <- Config.configBool "search_enabled" False cfg
    retention <- Config.configInt "trash_retention_days" defaultTrashRetentionDays cfg
    searchTokens <- Config.configInt "search_max_tokens" 384 cfg
    searchDim <- Config.configInt "search_dims" 384 cfg
    searchThr <- Config.configInt "search_threads" 4 cfg
    treeRoot <- case Config.configString "document_tree_root" "" cfg of
        "" -> Left (Config.ConfigError "document_tree_root is required (the directory of the document tree to serve)")
        root -> Right root
    pure
        VersoConfig
            { documentTreeRoot = treeRoot
            , editorTheme = Config.configString "editor_theme" "shadcn" cfg
            , operationLog = Config.configString "operation_log" "data/operation_log" cfg
            , trashRoot = Config.configString "trash_root" "data/trash" cfg
            , trashRetentionDays = retention
            , linkIndex = Config.configString "link_index" "data/link_index" cfg
            , accessLog = Config.configString "access_log" "build/access.log" cfg
            , clientErrorLog = Config.configString "client_error_log" "build/client-errors.log" cfg
            , logMaxBytes = maxBytes
            , logKeep = keep
            , staticMounts = Config.configMounts "static_mounts" cfg
            , versioningEnabled = versioning
            , linkIndexEnabled = indexEnabled
            , draftRoot = Config.configString "draft_root" "data/drafts" cfg
            , identityHeader = Config.configString "identity_header" "X-Remote-User" cfg
            , identityDefault = Config.configString "identity_default" "anonymous" cfg
            , identityEmailDomain = Config.configString "identity_email_domain" "verso.local" cfg
            , searchEnabled = searchOn
            , searchModel = Config.configString "search_model" "" cfg
            , searchVocab = Config.configString "search_vocab" "" cfg
            , searchIndexDir = Config.configString "search_index" "data/search_index" cfg
            , searchModelId = Config.configString "search_model_id" "bge-small-en-v1.5-q8" cfg
            , searchPooling = Config.configString "search_pooling" "cls" cfg
            , searchMaxTokens = searchTokens
            , searchDims = searchDim
            , searchThreads = searchThr
            , searchQueryPrefix = Config.configString "search_query_prefix" "" cfg
            }

{- | Loads the configuration file, layering the framework's @MICROHTTP_@ overlay
(server keys) and the application's @VERSO_@ overlay (application keys) from the
environment. This is the application's single entry into configuration.
-}
loadConfig :: FilePath -> IO (Either Config.ConfigError Config.Config)
loadConfig = Config.loadConfigWith [("MICROHTTP_", Config.serverEnvKeys), ("VERSO_", appEnvKeys)]
