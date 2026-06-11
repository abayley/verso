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

data ParseLimits = ParseLimits
    { maxHeaderBytes :: Int
    , maxBodyBytes :: Int
    }
    deriving (Eq, Show)

defaultParseLimits :: ParseLimits
defaultParseLimits =
    ParseLimits
        { maxHeaderBytes = 8192
        , maxBodyBytes = 1048576
        }

data ParseError
    = BadRequest String
    | HeaderTooLarge
    | BodyTooLarge
    | UnsupportedMethod BS.ByteString
    | UnsupportedTransferEncoding
    | UnsupportedHttpVersion
    deriving (Eq, Show)
