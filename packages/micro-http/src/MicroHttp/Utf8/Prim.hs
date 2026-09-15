{- | The UTF-8 primitives under 'MicroHttp.Utf8', MicroHs build: the runtime
decodes and encodes in C (@fromUTF8@ and @packUTF8@, the same primitives
behind 'Data.Text' and 'Foreign.C.String'), so a decode allocates one 'String'
and an encode one buffer, with no intermediate byte-per-'Char' list. The GHC
build takes the same two names from the shim in @test/ghc-compat@, which the
GHC search path lists first. Malformed input is undefined either way.
-}
module MicroHttp.Utf8.Prim (
    decodeBytes,
    encodeText,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Internal as Internal

-- | Decodes UTF-8 bytes into a 'String', in the runtime.
decodeBytes :: BS.ByteString -> String
decodeBytes = Internal.primBSfromUTF8

-- | Encodes a 'String' as UTF-8 bytes, in the runtime.
encodeText :: String -> BS.ByteString
encodeText = Internal.packUTF8
