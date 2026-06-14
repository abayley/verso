{- | Configuration loading (RFC-0011). A flat @key = value@ file, parsed by
this module, with environment-variable overrides: any key @foo@ is overridden
by @MICROHTTP_FOO@, and the precedence is built-in defaults, then the file, then
the environment. The known server keys map to a 'Settings' via 'toSettings'
(failing fast on a bad value); an application reads its own keys with the typed
lookups. A missing file is an empty config, so defaults apply.
-}
module MicroHttp.Config (
    Config,
    ConfigError (..),
    parseConfig,
    loadConfig,
    applyEnvironment,
    toSettings,
    configString,
    configInt,
    configBool,
    configMounts,
) where

import Data.Char (isDigit, isSpace, toLower)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Word (Word8)
import MicroHttp.Network.Socket (Host (..), Port (..))
import MicroHttp.Server (Settings (..), defaultSettings)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)

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

{- | Reads the file (an absent file is empty), parses it, and overlays
environment variables: @MICROHTTP_FOO@ overrides key @foo@. Environment entries
win because they are placed first.
-}
loadConfig :: FilePath -> IO (Either ConfigError Config)
loadConfig path = do
    present <- doesFileExist path
    fileText <- if present then readFile path else return ""
    environment <- getEnvironment
    return (fmap (applyEnvironment environment) (parseConfig fileText))

{- | Overlays @MICROHTTP_FOO@ environment entries onto a parsed config as key
@foo@; the overrides win because they are placed first. Pure, so the override
behaviour is testable without the environment.
-}
applyEnvironment :: [(String, String)] -> Config -> Config
applyEnvironment environment (Config fileEntries) =
    Config (overrides ++ fileEntries)
  where
    overrides = [(keyOf name, value) | (name, value) <- environment, isOverride name]
    isOverride name = "MICROHTTP_" `isPrefixOf` name
    keyOf name = map toLower (drop (length "MICROHTTP_") name)

-- | Maps the known server keys onto 'defaultSettings', failing on a bad value.
toSettings :: Config -> Either ConfigError Settings
toSettings cfg = do
    host <- configHost "host" (settingsHost defaultSettings) cfg
    port <- configInt "port" (portNumber (settingsPort defaultSettings)) cfg
    backlog <- configInt "backlog" (settingsBacklog defaultSettings) cfg
    maxActive <- configInt "max_active_handlers" (settingsMaxActiveHandlers defaultSettings) cfg
    maxHeader <- configInt "max_header_bytes" (settingsMaxHeaderBytes defaultSettings) cfg
    maxBody <- configInt "max_body_bytes" (settingsMaxBodyBytes defaultSettings) cfg
    readBuffer <- configInt "read_buffer_bytes" (settingsReadBufferBytes defaultSettings) cfg
    idleRead <- configInt "idle_read_timeout_micros" (settingsIdleReadTimeoutMicros defaultSettings) cfg
    idleWrite <- configInt "idle_write_timeout_micros" (settingsIdleWriteTimeoutMicros defaultSettings) cfg
    return
        defaultSettings
            { settingsHost = host
            , settingsPort = Port port
            , settingsBacklog = backlog
            , settingsMaxActiveHandlers = maxActive
            , settingsMaxHeaderBytes = maxHeader
            , settingsMaxBodyBytes = maxBody
            , settingsReadBufferBytes = readBuffer
            , settingsIdleReadTimeoutMicros = idleRead
            , settingsIdleWriteTimeoutMicros = idleWrite
            }

portNumber :: Port -> Int
portNumber (Port n) = n

-- | A string value, or the default when the key is absent.
configString :: String -> String -> Config -> String
configString key def cfg = fromMaybe def (lookupConfig key cfg)

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

lookupConfig :: String -> Config -> Maybe String
lookupConfig key (Config entries) = lookup key entries

configHost :: String -> Host -> Config -> Either ConfigError Host
configHost key def cfg =
    case lookupConfig key cfg of
        Nothing -> Right def
        Just value ->
            case parseHost value of
                Just host -> Right host
                Nothing -> Left (ConfigError ("config key " ++ key ++ " expects a host, got: " ++ value))

parseHost :: String -> Maybe Host
parseHost "0.0.0.0" = Just HostAny
parseHost value =
    case splitOn '.' value of
        [a, b, c, d] ->
            case traverse octet [a, b, c, d] of
                Just [pa, pb, pc, pd] -> Just (HostIPv4 pa pb pc pd)
                _ -> Nothing
        _ -> Nothing

octet :: String -> Maybe Word8
octet s =
    case readInt s of
        Just n | n >= 0 && n <= 255 -> Just (fromIntegral n)
        _ -> Nothing

readInt :: String -> Maybe Int
readInt s
    | not (null s) && all isDigit s = Just (read s)
    | otherwise = Nothing

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
  where
    dropWhileEnd p = reverse . dropWhile p . reverse

splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]
