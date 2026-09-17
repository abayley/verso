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

A whole value and a block of a stream decode through the same walk, differing
only in whether more bytes can still arrive, so a value decoded in blocks is
byte-identical to the same value decoded whole (RFC-0042).
-}
module MicroHttp.Percent (
    PlusRule (..),
    decodeWhole,
    decodeBlock,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char

{- | What a literal @+@ means, which is the one way the two decoders differ: a
form value inherits it from HTML's form encoding, where it stands for a space; a
path segment has no such rule and keeps it.
-}
data PlusRule
    = PlusIsSpace
    | PlusIsLiteral
    deriving (Eq, Show)

{- | Decodes a whole value. Nothing can arrive after it, so a trailing @%@ that
begins no valid escape is malformed rather than incomplete, and the recovery rule
applies to it like any other.
-}
decodeWhole :: PlusRule -> BS.ByteString -> BS.ByteString
decodeWhole plusRule bytes = BS.pack (fst (walk True plusRule bytes))

{- | Decodes one block of a stream: the decoded bytes, and the tail to carry into
the next block, which the caller prepends to it. The carry is at most two bytes,
a @%@ and whatever single byte follows it, because only an escape can straddle a
block boundary; it is not always a partial escape, since a @%z@ at a block end is
carried too and resolves as malformed once the next block arrives.

At the end of a stream there is no next block, so the caller flushes what is left
through 'decodeWhole' rather than emitting it verbatim.

The cut comes from the same left-to-right walk the decoder takes, so an escape's
three bytes are never split from each other and a @%@ that is itself the tail of a
malformed escape is not mistaken for a carry. A per-block list is packed once; the
caller slices, so a block is bounded regardless of the chunk it came from.
-}
decodeBlock :: PlusRule -> BS.ByteString -> (BS.ByteString, BS.ByteString)
decodeBlock plusRule bytes = (BS.pack decoded, BS.drop cut bytes)
  where
    (decoded, cut) = walk False plusRule bytes

{- | The one walk, over a whole value or one block: the decoded characters, and
the index the carry starts at (the length when nothing is carried).

@final@ says whether more bytes can still arrive. It only matters at a @%@ with
fewer than two bytes after it: within a stream that is a carry, because the next
block may complete the escape, but at the end of a value there is nothing left to
complete it, so the @%@ is malformed and the recovery rule applies to it like any
other. Getting that wrong leaves the carry undecoded, which is how a trailing
@"%+"@ kept its @+@ instead of turning it into a space.

The walk yields the decoded characters and the cut together because a second pass
to find the cut would have to repeat this one's hex tests, and the cut cannot be
over-approximated: a carried complete escape would be flushed without decoding.
-}
walk :: Bool -> PlusRule -> BS.ByteString -> (String, Int)
walk final plusRule bytes = go 0
  where
    len = BS.length bytes
    go i
        | i >= len = ([], len)
        | c == '+' && plusRule == PlusIsSpace = emit ' ' (go (i + 1))
        | c /= '%' = emit c (go (i + 1))
        | i + 2 >= len = if final then emit c (go (i + 1)) else ([], i)
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
