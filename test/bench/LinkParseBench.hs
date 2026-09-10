{- | A measurement harness for the link-index page parse on the publish path
(open item from RFC-0036): 'Verso.DocumentLinks.pageLinks' walks every byte of
the page body in an interpreted loop, costing tens of MB of transient graph per
publish of a ~73KB page. This reports cells allocated (via 'System.RTS.getStats',
one cell = one graph node) and CPU time per parse for the current implementation
and any candidates, so a fix rests on numbers. Run with @make bench-link-parse@.
-}
module Main (main) where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import Data.List (foldl')
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Ptr as Ptr
import System.CPUTime (getCPUTime)
import qualified System.IO.Unsafe as Unsafe
import qualified System.RTS as RTS
import qualified Verso.DocumentLinks as DocumentLinks
import qualified Verso.LinkIndex as LinkIndex

foreign import ccall "string.h memchr" c_memchr :: CStr.CString -> CTypes.CInt -> CTypes.CSize -> IO (Ptr.Ptr ())

-- | Parses per measured strategy.
reps :: Int
reps = 5

main :: IO ()
main = do
    let body = pageBody
    putStrLn "link-parse bench: cells + time per parse of a publish-sized page"
    putStrLn
        ( "input = "
            ++ show (BS.length body)
            ++ " bytes, "
            ++ show (length (DocumentLinks.pageLinks body))
            ++ " links found, "
            ++ show reps
            ++ " reps/strategy"
        )
    putStrLn "strategy      | cells/parse | MB/parse | ms/parse"
    bench "pageLinks" (length . DocumentLinks.pageLinks) body
    bench "scan-4k" (length . DocumentLinks.scanChunks . chunksOf 4096) body
    bench "scan-64k" (length . DocumentLinks.scanChunks . chunksOf 65536) body
    bench "scan-128k" (length . DocumentLinks.scanChunks . chunksOf 131072) body
    bench "updatePage" (weigh . applyUpdate) body
    bench "lines-only" (length . BS.split '\n') body
    bench "unpack-walk" (length . unpackWalkLinks) body
    bench "memchr-scan" (length . memchrScanLinks) body
  where
    applyUpdate body = LinkIndex.updatePage "sec/page.md" body LinkIndex.emptyIndex
    weigh ix = length (LinkIndex.outboundOf "sec/page.md" ix)

-- candidate: unpack once, walk the String ------------------------------------

{- | A String-walk clone of the link scan: one eager 'BS.unpack', then a cons-pattern
walk instead of per-byte 'BS.index'. Measures whether list traversal beats indexed
access under the interpreter (the decode spike said roughly not, but that loop did
more per byte).
-}
unpackWalkLinks :: ByteString -> [(Int, String)]
unpackWalkLinks bytes = atLineStart False 0 (BS.unpack bytes)
  where
    atLineStart fence i cs
        | isFencePrefix cs = skipLine (not fence) i cs
        | fence = skipLine fence i cs
        | otherwise = inLine fence i cs
    inLine _ _ [] = []
    inLine fence i ('\n' : rest) = atLineStart fence (i + 1) rest
    inLine fence i (']' : '(' : rest) =
        case readTargetChars rest of
            Just (target, targetLen) -> (i + 2, target) : inLine fence (i + 2 + targetLen) (drop targetLen rest)
            Nothing -> inLine fence (i + 1) ('(' : rest)
    inLine fence i (_ : rest) = inLine fence (i + 1) rest
    skipLine fence i cs = case break (== '\n') cs of
        (_, []) -> []
        (line, _ : rest) -> atLineStart fence (i + length line + 1) rest
    isFencePrefix cs = "```" == take 3 cs || "~~~" == take 3 cs

-- | The target token after @](@ up to the closing paren, title excluded.
readTargetChars :: String -> Maybe (String, Int)
readTargetChars cs = case break (== ')') cs of
    (_, []) -> Nothing
    (inner, _) -> Just (takeWhile (\c -> c /= ' ' && c /= '\t') inner, length inner)

-- candidate: libc memchr scan -------------------------------------------------

{- | The scan done by libc memchr over one marshalled copy: newline hits find the
fence-marker lines, @]@ hits find the @](@ candidates, and Haskell touches only
those positions plus the short target slices -- no per-byte interpreted work.
-}
memchrScanLinks :: ByteString -> [(Int, String)]
memchrScanLinks bytes = Unsafe.unsafePerformIO $
    BS.useAsCStringLen bytes $ \(basePtr, len) -> do
        let findFrom i wanted
                | i >= len = pure Nothing
                | otherwise = do
                    p <- c_memchr (Ptr.plusPtr basePtr i) (fromIntegral (Char.ord wanted)) (fromIntegral (len - i))
                    pure (if p == Ptr.nullPtr then Nothing else Just (Ptr.minusPtr p basePtr))
            collect i wanted = do
                found <- findFrom i wanted
                case found of
                    Nothing -> pure []
                    Just j -> (j :) <$> collect (j + 1) wanted
        newlines <- collect 0 '\n'
        candidates <- collect 0 ']'
        let fenceToggles = [o + 1 | o <- 0 - 1 : newlines, isFenceAt (o + 1)]
            isFenceAt o = let t = BS.take 3 (BS.drop o bytes) in t == fenceBackticks || t == fenceTildes
            links = walk False fenceToggles [j | j <- candidates, j + 1 < len, BS.index bytes (j + 1) == '(']
            walk _ _ [] = pure []
            walk fence (t : ts) (c : cs)
                | t <= c = walk (not fence) ts (c : cs)
            walk True ts (_ : cs) = walk True ts cs
            walk False ts (c : cs) = do
                closing <- findFrom (c + 2) ')'
                case closing of
                    Nothing -> pure []
                    Just close ->
                        let raw = BS.takeWhile (\ch -> ch /= ' ' && ch /= '\t') (BS.take (close - c - 2) (BS.drop (c + 2) bytes))
                            rest = walk False ts (dropWhile (< close) cs)
                         in ((c + 2, BS.unpack raw) :) <$> rest
        links

fenceBackticks :: ByteString
fenceBackticks = BS.pack "```"

fenceTildes :: ByteString
fenceTildes = BS.pack "~~~"

-- | Measures cells allocated and CPU time across `reps` runs of a parse, forcing each result.
bench :: String -> (ByteString -> Int) -> ByteString -> IO ()
bench name force body = do
    statsBefore <- RTS.getStats
    t0 <- getCPUTime
    let total = foldl' (\acc i -> acc + force (vary i)) 0 [1 .. reps]
    total `seq` do
        t1 <- getCPUTime
        statsAfter <- RTS.getStats
        let cells = fromIntegral (RTS.cellsAllocated statsAfter - RTS.cellsAllocated statsBefore) `div` reps :: Int
            ms = fromIntegral (t1 - t0) / 1.0e9 / fromIntegral reps :: Double
            mb = fromIntegral (cells * 16) / 1048576 :: Double
        putStrLn (pad 14 name ++ "| " ++ pad 12 (show cells) ++ "| " ++ pad 9 (showFixed mb) ++ "| " ++ showFixed ms)
  where
    -- a per-rep prefix so no rep can reuse a previous result
    vary i = BS.append (BS.pack ("rep " ++ show i ++ "\n\n")) body

{- | A publish-sized Markdown body (~73KB) in the corpus's shape: prose
paragraphs, headings, scattered inline links and images, and a code fence.
-}
pageBody :: ByteString
pageBody = BS.pack (concat (replicate 90 section))
  where
    section =
        concat
            [ "## Section heading with some words\n\n"
            , concat (replicate 6 prose)
            , "See [the runbook](../ops/runbook.md) and [the guide](guides/setup.md#install) for details.\n\n"
            , "![diagram](assets/diagram.png)\n\n"
            , "```haskell\nmain :: IO ()\nmain = putStrLn \"hello\"\n```\n\n"
            ]
    prose = "The quick brown fox jumps over the lazy dog's back near the riverbank at dusk while herons watch quietly.\n"

-- | Splits a body into chunks of at most n bytes, as a file enumerator would feed it.
chunksOf :: Int -> ByteString -> [ByteString]
chunksOf n bytes
    | BS.null bytes = []
    | otherwise = let (a, b) = BS.splitAt n bytes in a : chunksOf n b

pad :: Int -> String -> String
pad n s = s ++ replicate (max 0 (n - length s)) ' '

showFixed :: Double -> String
showFixed x = show (fromIntegral (round (x * 100) :: Int) / 100 :: Double)
