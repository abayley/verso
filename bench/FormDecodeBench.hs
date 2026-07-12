{- | A measurement spike: can form-value percent-decoding be efficient in
Haskell under MicroHs? It decodes a realistic browser-encoded page body
(~85KB, @+@ for every space, @%0A@ line ends) many times through each
candidate and reports CPU time, so the where-does-the-byte-work-live decision
rests on numbers (RFC-0036). This is a measurement tool, not a pass/fail
test; run it with @make bench-form-decode@.

Strategies compared:

  * string       -- the original pipeline: BS.unpack -> String decode -> BS.pack
  * bs-index     -- per-byte Haskell loop over ByteString views (no Strings)
  * chunks-find  -- chunk-wise: Char8.findIndex scan, O(1) run views, escapes
                    decoded individually, balanced-tree BS.append reassembly
  * chunks-elem  -- as above but scanning with two Char8.elemIndex calls
  * chunks-ffi   -- chunk-wise with the scan done by libc memchr over one
                    marshalled copy (approximates a NATIVE mhs elemIndex; the
                    decode logic itself stays in Haskell)

A sixth strategy -- one whole-pass C decode -- measured 0.05ms/decode against
the numbers below (2026-07-12) and was removed with the interim C shim it
exercised; RFC-0036 records the comparison and chose raw request bodies
instead, so nothing on the hot path decodes at all.
-}
module Main (main) where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import Data.List (foldl')
import qualified Foreign.C.String as CStr
import qualified Foreign.C.Types as CTypes
import qualified Foreign.Ptr as Ptr
import qualified MicroHttp.Http as Http
import System.CPUTime (getCPUTime)
import qualified System.IO.Unsafe as Unsafe

foreign import ccall "string.h memchr" c_memchr :: CStr.CString -> CTypes.CInt -> CTypes.CSize -> IO (Ptr.Ptr ())

-- | Decodes per timed strategy.
reps :: Int
reps = 20

main :: IO ()
main = do
    putStrLn "form-decode spike: Haskell vs C for the per-byte pass"
    let body = encodedBody
        expected = stringDecode body
    putStrLn
        ( "input = "
            ++ show (BS.length body)
            ++ " bytes encoded, "
            ++ show (BS.length expected)
            ++ " decoded, "
            ++ show reps
            ++ " reps/strategy"
        )
    mapM_
        (checkAgainst expected)
        [ ("string", stringDecode)
        , ("bs-index", bsIndexDecode)
        , ("chunks-find", chunksFindDecode)
        , ("chunks-elem", chunksElemDecode)
        , ("chunks-ffi", chunksFfiDecode)
        ]
    putStrLn "strategy      | total ms | ms/decode"
    bench "string" stringDecode body
    bench "bs-index" bsIndexDecode body
    bench "chunks-find" chunksFindDecode body
    bench "chunks-elem" chunksElemDecode body
    bench "chunks-ffi" chunksFfiDecode body

-- | Fails loudly if a strategy decodes differently from the String baseline.
checkAgainst :: ByteString -> (String, ByteString -> ByteString) -> IO ()
checkAgainst expected (name, f) =
    if f encodedBody == expected
        then pure ()
        else error (name ++ ": decoded output differs from the string baseline")

-- | Times a strategy across `reps` decodes, forcing each result's length.
bench :: String -> (ByteString -> ByteString) -> ByteString -> IO ()
bench name f body = do
    t0 <- getCPUTime
    let total = foldl' (\acc i -> acc + BS.length (f (vary i))) 0 [1 .. reps]
    total `seq` do
        t1 <- getCPUTime
        let ms = fromIntegral (t1 - t0) / 1.0e9 :: Double
        putStrLn (pad 14 name ++ "| " ++ pad 9 (showFixed ms) ++ "| " ++ showFixed (ms / fromIntegral reps))
  where
    -- a per-rep prefix so no rep can reuse a previous result
    vary i = BS.append (BS.pack (show i ++ "+")) body

{- | A browser-style urlencoded page body: every space is @+@, every newline
@%0A@, apostrophes @%27@ -- the shape the editor's form post actually has.
-}
encodedBody :: ByteString
encodedBody = BS.pack (concat (replicate 800 line))
  where
    line = "The+quick+brown+fox+jumps+over+the+lazy+dog%27s+back+near+the+riverbank+at+dusk+while+herons+watch%0A"

-- strategy: string ----------------------------------------------------------

stringDecode :: ByteString -> ByteString
stringDecode = BS.pack . Http.decodeFormValue . BS.unpack

-- strategy: bs-index --------------------------------------------------------

-- | Per-byte index loop over the ByteString, one output pack.
bsIndexDecode :: ByteString -> ByteString
bsIndexDecode bytes = BS.pack (go 0)
  where
    len = BS.length bytes
    go i
        | i >= len = []
        | c == '%' && i + 2 < len =
            case hexPair (BS.index bytes (i + 1)) (BS.index bytes (i + 2)) of
                Just decoded -> decoded : go (i + 3)
                Nothing -> '%' : BS.index bytes (i + 1) : BS.index bytes (i + 2) : go (i + 3)
        | c == '+' = ' ' : go (i + 1)
        | otherwise = c : go (i + 1)
      where
        c = BS.index bytes i

-- strategy: chunks-find -----------------------------------------------------

-- | Chunk-wise: runs between escapes stay O(1) views; findIndex scans.
chunksFindDecode :: ByteString -> ByteString
chunksFindDecode = treeConcat . chunks
  where
    chunks rest = case BS.findIndex isEscape rest of
        Nothing -> [rest]
        Just i -> BS.take i rest : escape (BS.index rest i) (BS.drop i rest)
    escape '+' rest = spaceChunk : chunks (BS.drop 1 rest)
    escape _ rest
        | BS.length rest >= 3 =
            case hexPair (BS.index rest 1) (BS.index rest 2) of
                Just decoded -> BS.pack [decoded] : chunks (BS.drop 3 rest)
                Nothing -> BS.take 3 rest : chunks (BS.drop 3 rest)
        | otherwise = [rest]
    isEscape c = c == '%' || c == '+'

spaceChunk :: ByteString
spaceChunk = BS.pack " "

-- strategy: chunks-elem -----------------------------------------------------

-- | Chunk-wise with two elemIndex scans instead of a predicate findIndex.
chunksElemDecode :: ByteString -> ByteString
chunksElemDecode = treeConcat . chunks
  where
    chunks rest = case nearest (BS.elemIndex '%' rest) (BS.elemIndex '+' rest) of
        Nothing -> [rest]
        Just i -> BS.take i rest : escape (BS.index rest i) (BS.drop i rest)
    escape '+' rest = spaceChunk : chunks (BS.drop 1 rest)
    escape _ rest
        | BS.length rest >= 3 =
            case hexPair (BS.index rest 1) (BS.index rest 2) of
                Just decoded -> BS.pack [decoded] : chunks (BS.drop 3 rest)
                Nothing -> BS.take 3 rest : chunks (BS.drop 3 rest)
        | otherwise = [rest]
    nearest (Just a) (Just b) = Just (min a b)
    nearest a Nothing = a
    nearest Nothing b = b

-- strategy: chunks-ffi ------------------------------------------------------

{- | Chunk-wise with the scan in libc memchr over one marshalled copy of the
input: what a native mhs elemIndex would cost. Decode decisions stay Haskell.
-}
chunksFfiDecode :: ByteString -> ByteString
chunksFfiDecode bytes = Unsafe.unsafePerformIO $
    BS.useAsCStringLen bytes $ \(basePtr, len) -> do
        let findFrom i wanted = do
                p <- c_memchr (Ptr.plusPtr basePtr i) (fromIntegral (Char.ord wanted)) (fromIntegral (len - i))
                pure (if p == Ptr.nullPtr then Nothing else Just (Ptr.minusPtr p basePtr))
            nearest (Just a) (Just b) = Just (min a b)
            nearest a Nothing = a
            nearest Nothing b = b
            chunks i
                | i >= len = pure []
                | otherwise = do
                    percent <- findFrom i '%'
                    plus <- findFrom i '+'
                    case nearest percent plus of
                        Nothing -> pure [slice i len]
                        Just j -> do
                            let run = slice i j
                            after <- escape j
                            pure (run : after)
            escape j
                | BS.index bytes j == '+' = (spaceChunk :) <$> chunks (j + 1)
                | j + 2 < len =
                    case hexPair (BS.index bytes (j + 1)) (BS.index bytes (j + 2)) of
                        Just decoded -> (BS.pack [decoded] :) <$> chunks (j + 3)
                        Nothing -> (slice j (j + 3) :) <$> chunks (j + 3)
                | otherwise = pure [slice j len]
            slice from to = BS.take (to - from) (BS.drop from bytes)
        treeConcat <$> chunks 0

-- shared helpers ------------------------------------------------------------

-- | Balanced pairwise append: O(n log k) memcpy instead of concat's O(n * k).
treeConcat :: [ByteString] -> ByteString
treeConcat [] = BS.empty
treeConcat [x] = x
treeConcat xs = treeConcat (pairUp xs)
  where
    pairUp (a : b : rest) = BS.append a b : pairUp rest
    pairUp rest = rest

-- | Decodes two hex digits (mirrors the Http-internal helper).
hexPair :: Char -> Char -> Maybe Char
hexPair a b = (\high low -> Char.chr (high * 16 + low)) <$> hexValue a <*> hexValue b

hexValue :: Char -> Maybe Int
hexValue c
    | Char.isDigit c = Just (Char.ord c - Char.ord '0')
    | 'a' <= c && c <= 'f' = Just (10 + Char.ord c - Char.ord 'a')
    | 'A' <= c && c <= 'F' = Just (10 + Char.ord c - Char.ord 'A')
    | otherwise = Nothing

pad :: Int -> String -> String
pad n s = s ++ replicate (max 0 (n - length s)) ' '

showFixed :: Double -> String
showFixed x = show (fromIntegral (round (x * 100) :: Int) / 100 :: Double)
