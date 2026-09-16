{- | Percent-decoding, once, over bytes.

A percent-escape is @%@ followed by two hexadecimal digits standing for one byte
(RFC 3986 section 2.1). The bytes those escapes spell are not characters: a
decoded value is UTF-8 that a caller reads with 'MicroHttp.Utf8.decodeUtf8' when
it wants text, which is why this module works on 'BS.ByteString' and the @String@
callers come through it rather than the other way round (RFC-0043).

RFC 3986 gives the grammar but no recovery rule for input that breaks it. This
module follows the WHATWG URL standard's percent-decode algorithm: a @%@ that is
not followed by two hexadecimal digits is emitted as itself and the scan advances
one byte, so the @%41@ in @%%41@ still decodes. Decoding never rescans its own
output, so @%2541@ is @%41@ and not @A@.

Both a whole value and a block of a stream decode through the same walk
('decodeBlock'), so a value decoded in blocks is byte-identical to the same value
decoded whole (RFC-0042).
-}
module MicroHttp.Percent (
    decodeWhole,
    decodeBlock,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char

{- | Decodes a whole value: no escape can be left incomplete, so a trailing bare
@%@ or truncated escape is emitted verbatim.
-}
decodeWhole :: Bool -> BS.ByteString -> BS.ByteString
decodeWhole plusIsSpace bytes = BS.append decoded carry
  where
    (decoded, carry) = decodeBlock plusIsSpace bytes

{- | Decodes one block of a stream: the decoded bytes, and the undecodable tail to
carry into the next block. The carry is at most two bytes, a @%@ and one hex
digit, because only an escape can straddle a block boundary. When the flag is set
a literal @+@ becomes a space, the form-value rule; a path segment keeps it.

The cut is found by the same left-to-right walk the decoder takes, so an escape's
three bytes are never split from each other and a @%@ that is itself the tail of a
malformed escape is not mistaken for a carry. A per-block list is packed once; a
block is at most a stream chunk plus two bytes.
-}
decodeBlock :: Bool -> BS.ByteString -> (BS.ByteString, BS.ByteString)
decodeBlock plusIsSpace bytes = (BS.pack decoded, BS.drop cut bytes)
  where
    len = BS.length bytes
    -- One walk yields both the decoded bytes and where the carry starts. The
    -- carry cannot be over-approximated -- it is flushed verbatim, so carrying a
    -- complete escape would leave it undecoded -- and a second pass to find it
    -- exactly would have to repeat this one's hex tests.
    (decoded, cut) = go 0
    go i
        | i >= len = ([], len)
        | c == '+' && plusIsSpace = emit ' ' (go (i + 1))
        | c /= '%' = emit c (go (i + 1))
        -- Too few bytes left to tell: it may complete in the next block.
        | i + 2 >= len = ([], i)
        | Char.isHexDigit hi && Char.isHexDigit lo = emit (hexPair hi lo) (go (i + 3))
        | otherwise = emit c (go (i + 1))
      where
        c = BS.index bytes i
        hi = BS.index bytes (i + 1)
        lo = BS.index bytes (i + 2)
    emit c (cs, end) = (c : cs, end)

-- | The byte two hexadecimal digits name; the caller has checked both are digits.
hexPair :: Char -> Char -> Char
hexPair a b = Char.chr (Char.digitToInt a * 16 + Char.digitToInt b)
