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
    , documentRoot :: String
    , attachmentRoot :: String
    , editorTheme :: String
    , operationLog :: String
    , trashRoot :: String
    , linkIndex :: String
    , accessLog :: String
    , clientErrorLog :: String
    , logMaxBytes :: Int
    , logKeep :: Int
    , staticMounts :: [(String, String)]
    , versioningEnabled :: Bool
    , draftRoot :: String
    , identityHeader :: String
    , identityDefault :: String
    , identityEmailDomain :: String
    }
    deriving (Eq, Show)

{- | The application keys, owned by the @VERSO_@ environment overlay. Listed here
so the overlay can be scoped to exactly these keys (RFC-0030).
-}
appEnvKeys :: [String]
appEnvKeys =
    [ "document_tree_root"
    , "document_root"
    , "attachment_root"
    , "editor_theme"
    , "operation_log"
    , "trash_root"
    , "link_index"
    , "access_log"
    , "client_error_log"
    , "log_max_bytes"
    , "log_keep"
    , "static_mounts"
    , "versioning_enabled"
    , "draft_root"
    , "identity_header"
    , "identity_default"
    , "identity_email_domain"
    ]

-- | The default log-rotation threshold in bytes (10 MiB) and retained-file count (RFC-0024).
defaultLogMaxBytes :: Int
defaultLogMaxBytes = 10485760

-- | The default count of rotated log files to retain (RFC-0024).
defaultLogKeep :: Int
defaultLogKeep = 5

{- | Reads the application's keys into a 'VersoConfig', failing fast on a
malformed integer (matching 'MicroHttp.Config.toSettings' for server keys). An
absent key takes its built-in default.
-}
fromConfig :: Config.Config -> Either Config.ConfigError VersoConfig
fromConfig cfg = do
    maxBytes <- Config.configInt "log_max_bytes" defaultLogMaxBytes cfg
    keep <- Config.configInt "log_keep" defaultLogKeep cfg
    versioning <- Config.configBool "versioning_enabled" True cfg
    pure
        VersoConfig
            { documentTreeRoot = Config.configString "document_tree_root" "" cfg
            , documentRoot = Config.configString "document_root" "data/documents" cfg
            , attachmentRoot = Config.configString "attachment_root" "data/attachments" cfg
            , editorTheme = Config.configString "editor_theme" "paper" cfg
            , operationLog = Config.configString "operation_log" "data/operation_log" cfg
            , trashRoot = Config.configString "trash_root" "data/trash" cfg
            , linkIndex = Config.configString "link_index" "data/link_index" cfg
            , accessLog = Config.configString "access_log" "build/access.log" cfg
            , clientErrorLog = Config.configString "client_error_log" "build/client-errors.log" cfg
            , logMaxBytes = maxBytes
            , logKeep = keep
            , staticMounts = Config.configMounts "static_mounts" cfg
            , versioningEnabled = versioning
            , draftRoot = Config.configString "draft_root" "data/drafts" cfg
            , identityHeader = Config.configString "identity_header" "X-Remote-User" cfg
            , identityDefault = Config.configString "identity_default" "anonymous" cfg
            , identityEmailDomain = Config.configString "identity_email_domain" "verso.local" cfg
            }

{- | Loads the configuration file, layering the framework's @MICROHTTP_@ overlay
(server keys) and the application's @VERSO_@ overlay (application keys) from the
environment. This is the application's single entry into configuration.
-}
loadConfig :: FilePath -> IO (Either Config.ConfigError Config.Config)
loadConfig = Config.loadConfigWith [("MICROHTTP_", Config.serverEnvKeys), ("VERSO_", appEnvKeys)]
