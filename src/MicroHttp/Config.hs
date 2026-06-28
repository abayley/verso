{- | Generic configuration loading (RFC-0011, RFC-0030). A flat @key = value@
file, parsed by this module, with environment-variable overrides scoped by
prefix and key set: 'applyEnvironment' overlays @PREFIX_FOO@ onto key @foo@ but
only for keys it is told to own, so a framework prefix and an application prefix
overlay disjoint key domains without leaking into each other. The precedence is
built-in defaults, then the file, then the environment. The known server keys
('serverEnvKeys') map to a 'Settings' via 'toSettings' (failing fast on a bad
value); an application owns its own keys and reads them with the typed lookups. A
missing file is an empty config, so defaults apply. 'loadConfigWith' reads the
file and environment once and applies a caller-supplied list of overlays, so the
application is responsible for creating both the framework config and its own.
-}
module MicroHttp.Config (
    Config,
    ConfigError (..),
    parseConfig,
    loadConfigWith,
    applyEnvironment,
    serverEnvKeys,
    toSettings,
    configString,
    configInt,
    configBool,
    configMounts,
) where

import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Data.Word as Word
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Settings as Settings
import qualified System.Directory as Directory
import qualified System.Environment as Environment

-- | A parsed configuration: key/value entries, earliest entry winning.
newtype Config = Config [(String, String)]

-- | A malformed line or a bad typed value.
newtype ConfigError = ConfigError String
    deriving (Eq, Show)

{- | Parses @key = value@ text: blank lines and @#@ comments are ignored,
whitespace is trimmed, and a non-blank line without an @=@ is an error.
-}
parseConfig :: String -> Either ConfigError Config
parseConfig text =
    fmap Config (traverse parseLine (filter meaningful (map trim (lines text))))
  where
    meaningful line = not (null line) && not (isComment line)
    isComment ('#' : _) = True
    isComment _ = False
    parseLine line =
        case break (== '=') line of
            (key, '=' : value) -> Right (trim key, trim value)
            _ -> Left (ConfigError ("malformed config line: " ++ line))

{- | Reads the file (an absent file is empty), parses it, and applies each
@(prefix, ownedKeys)@ overlay in turn from the environment, read once. The
application supplies the overlays so it creates both the framework config (the
@MICROHTTP_@ / 'serverEnvKeys' overlay) and its own (e.g. a @VERSO_@ overlay).
-}
loadConfigWith :: [(String, [String])] -> FilePath -> IO (Either ConfigError Config)
loadConfigWith overlays path = do
    present <- Directory.doesFileExist path
    fileText <- if present then readFile path else return ""
    environment <- Environment.getEnvironment
    return (fmap (overlay environment) (parseConfig fileText))
  where
    overlay environment cfg =
        foldl (\acc (prefix, keys) -> applyEnvironment prefix keys environment acc) cfg overlays

{- | Overlays @PREFIX_FOO@ environment entries onto a parsed config as key @foo@,
but only for keys in @ownedKeys@, so a prefix overlay never touches a key it does
not own. The overrides win because they are placed first. Pure, so the override
behaviour is testable without the environment.
-}
applyEnvironment :: String -> [String] -> [(String, String)] -> Config -> Config
applyEnvironment prefix ownedKeys environment (Config fileEntries) =
    Config (overrides ++ fileEntries)
  where
    overrides =
        [ (key, value)
        | (name, value) <- environment
        , prefix `List.isPrefixOf` name
        , let key = map Char.toLower (drop (length prefix) name)
        , key `elem` ownedKeys
        ]

{- | The known server keys, owned by the @MICROHTTP_@ environment overlay and
mapped onto 'Settings' by 'toSettings'. Listed here so the overlay can be scoped
to exactly these keys.
-}
serverEnvKeys :: [String]
serverEnvKeys =
    [ "host"
    , "port"
    , "backlog"
    , "max_active_handlers"
    , "max_header_bytes"
    , "max_body_bytes"
    , "read_buffer_bytes"
    , "idle_read_timeout_micros"
    , "idle_write_timeout_micros"
    ]

-- | Maps the known server keys onto 'defaultSettings', failing on a bad value.
toSettings :: Config -> Either ConfigError Settings.Settings
toSettings cfg = do
    host <- configHost "host" (Settings.settingsHost Settings.defaultSettings) cfg
    port <- configInt "port" (portNumber (Settings.settingsPort Settings.defaultSettings)) cfg
    backlog <- configInt "backlog" (Settings.settingsBacklog Settings.defaultSettings) cfg
    maxActive <- configInt "max_active_handlers" (Settings.settingsMaxActiveHandlers Settings.defaultSettings) cfg
    maxHeader <- configInt "max_header_bytes" (Settings.settingsMaxHeaderBytes Settings.defaultSettings) cfg
    maxBody <- configInt "max_body_bytes" (Settings.settingsMaxBodyBytes Settings.defaultSettings) cfg
    readBuffer <- configInt "read_buffer_bytes" (Settings.settingsReadBufferBytes Settings.defaultSettings) cfg
    idleRead <- configInt "idle_read_timeout_micros" (Settings.settingsIdleReadTimeoutMicros Settings.defaultSettings) cfg
    idleWrite <- configInt "idle_write_timeout_micros" (Settings.settingsIdleWriteTimeoutMicros Settings.defaultSettings) cfg
    return
        Settings.defaultSettings
            { Settings.settingsHost = host
            , Settings.settingsPort = Socket.Port port
            , Settings.settingsBacklog = backlog
            , Settings.settingsMaxActiveHandlers = maxActive
            , Settings.settingsMaxHeaderBytes = maxHeader
            , Settings.settingsMaxBodyBytes = maxBody
            , Settings.settingsReadBufferBytes = readBuffer
            , Settings.settingsIdleReadTimeoutMicros = idleRead
            , Settings.settingsIdleWriteTimeoutMicros = idleWrite
            }

-- | Extracts the numeric port from a 'Port'.
portNumber :: Socket.Port -> Int
portNumber (Socket.Port n) = n

-- | A string value, or the default when the key is absent.
configString :: String -> String -> Config -> String
configString key def cfg = Maybe.fromMaybe def (lookupConfig key cfg)

-- | An integer value, the default when absent, an error when present but not numeric.
configInt :: String -> Int -> Config -> Either ConfigError Int
configInt key def cfg =
    case lookupConfig key cfg of
        Nothing -> Right def
        Just value ->
            case readInt value of
                Just n -> Right n
                Nothing -> Left (ConfigError ("config key " ++ key ++ " expects an integer, got: " ++ value))

-- | A boolean value (@true@/@false@), the default when absent, an error otherwise.
configBool :: String -> Bool -> Config -> Either ConfigError Bool
configBool key def cfg =
    case lookupConfig key cfg of
        Nothing -> Right def
        Just "true" -> Right True
        Just "false" -> Right False
        Just value -> Left (ConfigError ("config key " ++ key ++ " expects true or false, got: " ++ value))

{- | Parses a comma-separated list of @<prefix> <root>@ mount pairs; entries
that are not exactly a prefix and a root are skipped. Absent key is no mounts.
-}
configMounts :: String -> Config -> [(String, String)]
configMounts key cfg =
    case lookupConfig key cfg of
        Nothing -> []
        Just value -> concatMap mountOf (splitOn ',' value)
  where
    mountOf entry =
        case words entry of
            [prefix, root] -> [(prefix, root)]
            _ -> []

-- | Looks up a key in the config entries, earliest entry winning.
lookupConfig :: String -> Config -> Maybe String
lookupConfig key (Config entries) = lookup key entries

-- | A host value, the default when absent, an error when present but not a host.
configHost :: String -> Socket.Host -> Config -> Either ConfigError Socket.Host
configHost key def cfg =
    case lookupConfig key cfg of
        Nothing -> Right def
        Just value ->
            case parseHost value of
                Just host -> Right host
                Nothing -> Left (ConfigError ("config key " ++ key ++ " expects a host, got: " ++ value))

-- | Parses a host: @0.0.0.0@ is any, otherwise a dotted IPv4 quad.
parseHost :: String -> Maybe Socket.Host
parseHost "0.0.0.0" = Just Socket.HostAny
parseHost value =
    case splitOn '.' value of
        [a, b, c, d] ->
            case traverse octet [a, b, c, d] of
                Just [pa, pb, pc, pd] -> Just (Socket.HostIPv4 pa pb pc pd)
                _ -> Nothing
        _ -> Nothing

-- | Parses a single IPv4 octet (0-255).
octet :: String -> Maybe Word.Word8
octet s =
    case readInt s of
        Just n | n >= 0 && n <= 255 -> Just (fromIntegral n)
        _ -> Nothing

-- | Parses a non-empty all-digit string as an 'Int', otherwise nothing.
readInt :: String -> Maybe Int
readInt s
    | not (null s) && all Char.isDigit s = Just (read s)
    | otherwise = Nothing

-- | Trims leading and trailing whitespace from a string.
trim :: String -> String
trim = dropWhileEnd Char.isSpace . dropWhile Char.isSpace
  where
    dropWhileEnd p = reverse . dropWhile p . reverse

-- | Splits a string on a separator character into segments.
splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]
