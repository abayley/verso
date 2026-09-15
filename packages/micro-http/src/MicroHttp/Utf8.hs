{- | UTF-8 conversion between bytes and real decoded 'String's. MicroHs has no
utf8-string package in its default database, so the framework carries this
small permissive codec: malformed input passes through byte-wise rather than
failing.

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
import qualified Data.Char as Char

-- | Decodes UTF-8 bytes into a 'String'.
decodeBytes :: BS.ByteString -> String
decodeBytes = decodeUtf8 . BS.unpack

-- | Encodes a 'String' as UTF-8 bytes.
encodeText :: String -> BS.ByteString
encodeText = BS.pack . encodeUtf8

-- | Decodes UTF-8 held as one 'Char' per byte into real characters.
decodeUtf8 :: String -> String
decodeUtf8 [] = []
decodeUtf8 (b0 : rest0)
    | c0 < 0x80 = b0 : decodeUtf8 rest0
    | c0 >= 0xC0 && c0 < 0xE0 = multi 1 (c0 - 0xC0)
    | c0 >= 0xE0 && c0 < 0xF0 = multi 2 (c0 - 0xE0)
    | c0 >= 0xF0 && c0 < 0xF8 = multi 3 (c0 - 0xF0)
    | otherwise = b0 : decodeUtf8 rest0
  where
    c0 = Char.ord b0
    multi n lead =
        let conts = take n rest0
         in if length conts == n && all isCont conts
                then
                    Char.chr (foldl (\acc c -> acc * 64 + (Char.ord c - 0x80)) lead conts)
                        : decodeUtf8 (drop n rest0)
                else b0 : decodeUtf8 rest0
    isCont c = Char.ord c >= 0x80 && Char.ord c < 0xC0

-- | Encodes characters as UTF-8, one byte per output 'Char'.
encodeUtf8 :: String -> String
encodeUtf8 = concatMap enc
  where
    enc c
        | n < 0x80 = [c]
        | n < 0x800 = [byte (0xC0 + n `div` 64), cont n]
        | n < 0x10000 = [byte (0xE0 + n `div` 4096), cont (n `div` 64), cont n]
        | otherwise =
            [ byte (0xF0 + n `div` 262144)
            , cont (n `div` 4096)
            , cont (n `div` 64)
            , cont n
            ]
      where
        n = Char.ord c
    byte = Char.chr
    cont n = Char.chr (0x80 + n `mod` 64)
