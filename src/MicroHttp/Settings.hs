{- | Server configuration: the inert parameters the runtime
('MicroHttp.Server') consumes and the file/environment layer
('MicroHttp.Config') produces. It lives in its own module so neither the runtime
nor the config-file parser owns the type -- both import it, and 'MicroHttp.Config'
no longer depends on 'MicroHttp.Server' just to name a 'Settings'.
-}
module MicroHttp.Settings (
    Settings (..),
    defaultSettings,
    parseLimits,
) where

import MicroHttp.Http.Parser (ParseLimits (..))
import MicroHttp.Network.Socket (Host (..), Port (..))

{- | Server configuration. Pure, inert data: framing limits, the handler cap,
the read buffer, and the idle read/write timeouts. The access logger is not here
-- logging is a middleware (RFC-0012) the application composes.
-}
data Settings = Settings
    { settingsHost :: Host
    , settingsPort :: Port
    , settingsBacklog :: Int
    , settingsMaxActiveHandlers :: Int
    , settingsMaxHeaderBytes :: Int
    , settingsMaxBodyBytes :: Int
    , settingsReadBufferBytes :: Int
    , settingsIdleReadTimeoutMicros :: Int
    , settingsIdleWriteTimeoutMicros :: Int
    }
    deriving (Eq, Show)

defaultSettings :: Settings
defaultSettings =
    Settings
        { settingsHost = HostAny
        , settingsPort = Port 8080
        , settingsBacklog = 16
        , settingsMaxActiveHandlers = 32
        , settingsMaxHeaderBytes = 8192
        , -- The framing body cap applies to every route; it must be at least the attachment upload
          -- limit (RFC-0018, MicroHttp.Attachment.attachmentMaxBytes = 10 MiB). Handlers still apply
          -- their own tighter bounds (e.g. the document form keeps a 1 MiB limit).
          settingsMaxBodyBytes = 10485760
        , settingsReadBufferBytes = 8192
        , settingsIdleReadTimeoutMicros = 30000000
        , settingsIdleWriteTimeoutMicros = 30000000
        }

-- | The 'ParseLimits' derived from settings, for an application's framing.
parseLimits :: Settings -> ParseLimits
parseLimits settings =
    ParseLimits
        { maxHeaderBytes = settingsMaxHeaderBytes settings
        , maxBodyBytes = settingsMaxBodyBytes settings
        }
