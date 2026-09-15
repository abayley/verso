{- | UTF-8 conversion between bytes and real decoded 'String's. MicroHs has no
utf8-string package in its default database, so the framework carries this
codec over the runtime's own primitives; malformed input is undefined.

The byte side is a 'BS.ByteString' ('decodeBytes', 'encodeText'). The
byte-per-'Char' 'String' forms ('decodeUtf8', 'encodeUtf8') exist for C
buffers and the tokeniser; a byte-per-'Char' 'String' must never travel
further than the call that decodes it. A file name, a form field or a header
value that reaches application code as a 'String' has been decoded (RFC-0043).
-}
module MicroHttp.Utf8 (
    decodeBytes,
    encodeText,
    decodeUtf8,
    encodeUtf8,
) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Utf8.Prim as Prim

-- | Decodes UTF-8 bytes into a 'String' (the runtime's decoder under MicroHs, @text@'s under GHC).
decodeBytes :: BS.ByteString -> String
decodeBytes = Prim.decodeBytes

-- | Encodes a 'String' as UTF-8 bytes.
encodeText :: String -> BS.ByteString
encodeText = Prim.encodeText

{- | Decodes UTF-8 held as one 'Char' per byte into real characters: the
byte-per-'Char' form a C buffer or a percent-decode yields. Packs and decodes in
the runtime; there is no interpreted decoder here any more.
-}
decodeUtf8 :: String -> String
decodeUtf8 = decodeBytes . BS.pack

-- | Encodes characters as UTF-8, one byte per output 'Char' (for a C buffer).
encodeUtf8 :: String -> String
encodeUtf8 = BS.unpack . encodeText
