{- | A page's lines as byte ranges, and the tests on a line that more than one
reader needs.

Reading a page by line ranges rather than by splitting it is the constant-space
rule (RFC-0043): the line ends come from libc @memchr@, so the interpreter never
walks the bytes between them, and a line is an O(1) view taken only when its
bytes are actually wanted. A whole-page @BS.lines@ would build a list of every
line instead, which is the MicroHs list-scan hazard.

This module exists because two readers need the same scan for different reasons:
'Verso.SearchChunks' walks a page's lines to cut it into index chunks, and
'Verso.Frontmatter' walks them to find the delimited block at the top. The scan
was the chunker's, and the frontmatter parser imported the search module to
borrow it, which put a page's metadata downstream of the search index. Neither
owns it, so it lives here and both import it.
-}
module Verso.PageLines (
    Range,
    lineRanges,
    viewOf,
    isDashesLine,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Unsafe as BSU
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Ptr as Ptr

foreign import ccall "string.h memchr" c_memchr :: CStr.CString -> CTypes.CInt -> CTypes.CSize -> IO (Ptr.Ptr ())

-- | A half-open byte range @[start, end)@ into the page content.
type Range = (Int, Int)

{- | The page's lines as byte ranges (excluding the newline), with 'lines'
semantics (no empty final line after a trailing newline). The line ends come
from libc @memchr@ so the interpreter never walks the bytes between them.
-}
lineRanges :: BS.ByteString -> IO [Range]
lineRanges content =
    BSU.unsafeUseAsCStringLen content $ \(basePtr, len) -> do
        let findNewline i
                | i >= len = pure Nothing
                | otherwise = do
                    p <- c_memchr (Ptr.plusPtr basePtr i) 10 (fromIntegral (len - i))
                    pure (if p == Ptr.nullPtr then Nothing else Just (Ptr.minusPtr p basePtr))
            go start
                | start >= len = pure []
                | otherwise = do
                    newline' <- findNewline start
                    case newline' of
                        Nothing -> pure [(start, len)]
                        Just j -> ((start, j) :) <$> go (j + 1)
        go 0

-- | The bytes of a range as an O(1) view.
viewOf :: BS.ByteString -> Range -> BS.ByteString
viewOf content (s, e) = BS.take (e - s) (BS.drop s content)

{- | Whether the line is a frontmatter delimiter: @---@ alone on the line,
with spaces, tabs, and a carriage return tolerated on either side. One rule
for the search chunker and 'Verso.Frontmatter'.
-}
isDashesLine :: BS.ByteString -> Range -> Bool
isDashesLine content (s, e) = dashes (skipBlanks s)
  where
    dashes k =
        k + 3 <= e
            && BS.index content k == '-'
            && BS.index content (k + 1) == '-'
            && BS.index content (k + 2) == '-'
            && skipBlanks (k + 3) == e
    -- Past any run of spaces, tabs, and carriage returns from k.
    skipBlanks k
        | k < e && (BS.index content k == ' ' || BS.index content k == '\t' || BS.index content k == '\r') = skipBlanks (k + 1)
        | otherwise = k
