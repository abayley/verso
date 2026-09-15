{- | GHC stand-in for the MicroHs-primitive UTF-8 codec behind 'MicroHttp.Utf8'
(the real one is @packages/micro-http/src/MicroHttp/Utf8/Prim.hs@; this
directory precedes it on the GHC search path). The @text@ package's decoder
replaces malformed input with U+FFFD, where MicroHs's is undefined; nothing in
the tree depends on either.
-}
module MicroHttp.Utf8.Prim (
    decodeBytes,
    encodeText,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding

-- | Decodes UTF-8 bytes into a 'String'.
decodeBytes :: BS.ByteString -> String
decodeBytes = Text.unpack . Encoding.decodeUtf8Lenient

-- | Encodes a 'String' as UTF-8 bytes.
encodeText :: String -> BS.ByteString
encodeText = Encoding.encodeUtf8 . Text.pack
