{- | A measurement harness for the search indexing pipeline's per-page cost
(RFC-0034 open item): decode, chunking, and WordPiece tokenisation each walk
the page in interpreted code. Reports cells allocated ('System.RTS.getStats')
and CPU time per phase for a publish-sized page, so a fix rests on numbers.
Run with @make bench-search-chunk@ (needs the vocab from @make search-model@).
-}
module Main (main) where

import qualified Concordance.Utf8 as Utf8
import qualified Concordance.WordPiece as WordPiece
import Data.ByteString.Char8 (ByteString)
import qualified Data.Char as Char
import qualified Data.ByteString.Char8 as BS
import Data.List (foldl')
import System.CPUTime (getCPUTime)
import qualified System.Directory as Directory
import qualified System.RTS as RTS
import qualified Verso.SearchChunks as SearchChunks

-- | Runs per measured phase.
reps :: Int
reps = 5

-- | The token budget per chunk (the server's default profile).
tokenCap :: Int
tokenCap = 384

-- | The chunk size cap in characters (mirrors SearchIndex.chunkCapChars).
chunkCap :: Int
chunkCap = 2000

main :: IO ()
main = do
    let body = pageBody
        content = Utf8.decodeUtf8 (BS.unpack body)
        chunks = SearchChunks.chunkPage chunkCap "Bench Page" content
    vocabPath <- firstExisting vocabCandidates
    vocab <- WordPiece.mkVocab <$> BS.readFile vocabPath
    putStrLn "search-chunk bench: cells + time per phase for a publish-sized page"
    putStrLn
        ( "input = "
            ++ show (BS.length body)
            ++ " bytes, "
            ++ show (length chunks)
            ++ " chunks, "
            ++ show reps
            ++ " reps/phase"
        )
    putStrLn "phase         | cells/run   | MB/run   | ms/run"
    bench "decode" (length . Utf8.decodeUtf8 . BS.unpack) body
    bench "tolower" (length . map Char.toLower . Utf8.decodeUtf8 . BS.unpack) body
    bench "punct-test" (length . filter (\c -> Char.isPunctuation c || Char.isSymbol c) . Utf8.decodeUtf8 . BS.unpack) body
    bench "token-split" (length . concatMap splitPunct . words . map Char.toLower . Utf8.decodeUtf8 . BS.unpack) body
    bench "chunkPage" (length . SearchChunks.chunkPage chunkCap "Bench Page" . Utf8.decodeUtf8 . BS.unpack) body
    bench "encode-all" (encodeAll vocab . SearchChunks.chunkPage chunkCap "Bench Page" . Utf8.decodeUtf8 . BS.unpack) body
  where
    encodeAll vocab pageChunks =
        sum [length (WordPiece.encodedIds (WordPiece.encode vocab tokenCap (SearchChunks.chunkText c))) | c <- pageChunks]

-- | A replica of the WordPiece basic-tokenise split (fast ASCII punctuation test).
splitPunct :: String -> [String]
splitPunct = go []
  where
    go acc [] = flush acc []
    go acc (c : rest)
        | isP c = flush acc ([c] : go [] rest)
        | otherwise = go (c : acc) rest
    flush acc more = if null acc then more else reverse acc : more
    isP c =
        (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')

-- | The first existing vocab path (per-platform model dirs), or fails loudly.
firstExisting :: [FilePath] -> IO FilePath
firstExisting [] = error "no vocab.txt found; run `make search-model` first"
firstExisting (p : ps) = do
    ok <- Directory.doesFileExist p
    if ok then pure p else firstExisting ps

vocabCandidates :: [FilePath]
vocabCandidates =
    [ "vendor/search/darwin-arm64/model/vocab.txt"
    , "vendor/search/darwin-x86_64/model/vocab.txt"
    , "vendor/search/linux-x86_64/model/vocab.txt"
    , "vendor/search/linux-aarch64/model/vocab.txt"
    ]

-- | Measures cells allocated and CPU time across `reps` runs, forcing each result.
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
    vary i = BS.append (BS.pack ("rep " ++ show i ++ "\n\n")) body

{- | A publish-sized Markdown body (~73KB) in the corpus's shape: headings,
prose paragraphs, scattered links, and a code fence per section.
-}
pageBody :: ByteString
pageBody = BS.pack (concat (replicate 90 section))
  where
    section =
        concat
            [ "## Section heading with some words\n\n"
            , concat (replicate 3 (prose ++ "\n" ++ prose ++ "\n\n"))
            , "See [the runbook](../ops/runbook.md) and [the guide](guides/setup.md#install) for details.\n\n"
            , "```haskell\nmain :: IO ()\nmain = putStrLn \"hello\"\n```\n\n"
            ]
    prose = "The quick brown fox jumps over the lazy dog's back near the riverbank at dusk while herons watch quietly."

pad :: Int -> String -> String
pad n s = s ++ replicate (max 0 (n - length s)) ' '

showFixed :: Double -> String
showFixed x = show (fromIntegral (round (x * 100) :: Int) / 100 :: Double)
