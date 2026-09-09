{- | Parser error and limit types, kept free of any other HTTP module so they
can be shared by the parser and by the stream error vocabulary without an
import cycle.
-}
module MicroHttp.Http.Parse (
    ParseError (..),
    ParseLimits (..),
    defaultParseLimits,
) where

import qualified Data.ByteString as BS

{- | Size limits applied while parsing a request, guarding against oversized
headers and bodies.
-}
data ParseLimits = ParseLimits
    { maxHeaderBytes :: Int
    , maxBodyBytes :: Int
    }
    deriving (Eq, Show)

-- | Conservative default limits: 8 KiB of headers and 1 MiB of body.
defaultParseLimits :: ParseLimits
defaultParseLimits =
    ParseLimits
        { maxHeaderBytes = 8192
        , maxBodyBytes = 1048576
        }

-- | Reasons a request could not be parsed or was rejected before dispatch.
data ParseError
    = BadRequest String
    | HeaderTooLarge
    | BodyTooLarge
    | UnsupportedMethod BS.ByteString
    | UnsupportedTransferEncoding
    | UnsupportedHttpVersion
    deriving (Eq, Show)
