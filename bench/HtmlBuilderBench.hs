{- | A measurement spike for RFC-0013: which HTML builder representation is
worth adopting under MicroHs. It renders a representative page (many small
constant tag fragments plus dynamic, escaped text) many times through each
candidate strategy and reports CPU time, so the representation decision rests on
numbers rather than guesswork. This is a measurement tool, not a pass/fail test;
run it with `make bench-html-builder`.

Strategies compared:

  * current     -- the live path: the MicroHttp.Html String writer, then BS.pack
  * bs-naive    -- left-nested BS.append of fragments into one strict ByteString
  * dlist-concat-- difference list ([ByteString] -> [ByteString]) then BS.concat
  * dlist-stream-- difference list, summed per chunk (models sinkChunk, no concat)
  * rope-concat -- a chunk tree (O(1) append) flattened then BS.concat
  * rope-stream -- a chunk tree, summed per chunk (models sinkChunk, no concat)

It also isolates the constant-fragment cost: packing a literal on every use
versus sharing a pre-packed CAF.
-}
module Main (main) where

import qualified Data.ByteString.Char8 as BS
import Data.ByteString.Char8 (ByteString)
import Data.List (foldl')
import qualified MicroHttp.Html as Html
import MicroHttp.Network.Socket
import System.CPUTime (getCPUTime)

-- | Elements emitted per rendered page.
pageItems :: Int
pageItems = 200

-- | Pages rendered per timed strategy.
reps :: Int
reps = 4000

-- | Pages sent per socket-write strategy.
socketReps :: Int
socketReps = 3000

-- | Coalescing buffer size, modelling a blaze-style buffer-filling builder.
coalesceBuf :: Int
coalesceBuf = 16384

-- | recv buffer for draining the loopback pair.
recvBuf :: Int
recvBuf = 32768

main :: IO ()
main = do
    putStrLn "RFC-0013 HTML builder representation spike"
    putStrLn ("page = " ++ show pageItems ++ " items, " ++ show reps ++ " pages/strategy")
    putStrLn "strategy      | bytes/page | total ms | ns/page"
    bench "current" (currentBytes . dynamicTexts)
    bench "bs-naive" (bsNaiveBytes . dynamicTexts)
    bench "dlist-concat" (dlistConcatBytes . dynamicTexts)
    bench "dlist-stream" (dlistStreamBytes . dynamicTexts)
    bench "dlist-coalesce" (dlistCoalesceBytes . dynamicTexts)
    bench "rope-concat" (ropeConcatBytes . dynamicTexts)
    bench "rope-stream" (ropeStreamBytes . dynamicTexts)
    putStrLn ""
    putStrLn "constant fragment cost (1,600,000 uses):"
    benchN 1600000 "pack-each" packEach
    benchN 1600000 "shared-caf" sharedCaf
    putStrLn ""
    putStrLn "chunks per page (each is one sinkChunk -> one sendAll on the socket):"
    let pageChunks = buildDList (dynamicTexts 1) []
    putStrLn ("  raw dlist        : " ++ show (length pageChunks))
    putStrLn ("  coalesced 16 KB  : " ++ show (length (coalesce coalesceBuf pageChunks)))
    putStrLn "  one-shot concat  : 1"
    putStrLn ""
    putStrLn ("socket write cost (connected loopback pair, " ++ show socketReps ++ " pages):")
    putStrLn "strategy      | sends/page | total ms | us/page"
    withConnectedPair
        ( \client served -> do
            socketBench "per-chunk" client served pageChunks
            socketBench "coalesced" client served (coalesce coalesceBuf pageChunks)
            socketBench "one-shot" client served [BS.concat pageChunks]
        )

-- | Times a per-page strategy across `reps` pages, forcing the byte total.
bench :: String -> (Int -> Int) -> IO ()
bench = benchN reps

-- | Times `n` iterations of an Int-returning function, forcing the running sum.
benchN :: Int -> String -> (Int -> Int) -> IO ()
benchN n name f = do
    t0 <- getCPUTime
    let total = foldl' (\acc i -> acc + f i) 0 [1 .. n]
    total `seq` do
        t1 <- getCPUTime
        let secs = fromIntegral (t1 - t0) / 1.0e12 :: Double
            nsEach = secs * 1.0e9 / fromIntegral n
        putStrLn
            ( pad 13 name
                ++ "| "
                ++ pad 10 (show (total `div` n))
                ++ " | "
                ++ pad 8 (showFixed (secs * 1000.0))
                ++ " | "
                ++ showFixed nsEach
            )

{- | The dynamic, per-page text fragments, varying with the page index so no
result can be cached. Each carries characters that require HTML escaping.
-}
dynamicTexts :: Int -> [String]
dynamicTexts i = [item j | j <- [1 .. pageItems]]
  where
    item j = "Row " ++ show (i + j) ++ " <a&b> \"q\" 'r'"

-- Shared constant tag fragments, packed once as CAFs.

openTag :: ByteString
openTag = BS.pack "<li class=\"row\">"

closeTag :: ByteString
closeTag = BS.pack "</li>"

-- | The live path: render through the String writer, then pack the whole page.
currentBytes :: [String] -> Int
currentBytes texts =
    BS.length (BS.pack (Html.renderHtml (mapM_ row texts)))
  where
    row t = Html.li_ [Html.class_ "row"] (Html.text t)

-- | Left-nested strict append of every fragment into one ByteString.
bsNaiveBytes :: [String] -> Int
bsNaiveBytes texts =
    BS.length (foldl' BS.append BS.empty (concatMap fragments texts))

-- | Difference list of chunks, flattened and concatenated to one ByteString.
dlistConcatBytes :: [String] -> Int
dlistConcatBytes texts =
    BS.length (BS.concat (buildDList texts []))

-- | Difference list of chunks, summed per chunk without concatenation.
dlistStreamBytes :: [String] -> Int
dlistStreamBytes texts =
    sumLengths (buildDList texts [])

-- | Difference list coalesced into buffer-sized segments, then summed per segment.
dlistCoalesceBytes :: [String] -> Int
dlistCoalesceBytes texts =
    sumLengths (coalesce coalesceBuf (buildDList texts []))

-- | Chunk tree, flattened and concatenated to one ByteString.
ropeConcatBytes :: [String] -> Int
ropeConcatBytes texts =
    BS.length (BS.concat (ropeToList (buildRope texts) []))

-- | Chunk tree, summed per chunk without concatenation.
ropeStreamBytes :: [String] -> Int
ropeStreamBytes texts =
    sumLengths (ropeToList (buildRope texts) [])

-- | The three byte fragments for one row: open tag, escaped text, close tag.
fragments :: String -> [ByteString]
fragments t = [openTag, escapeBytes (BS.pack t), closeTag]

-- A difference list of ByteString: O(1) append by composition.

buildDList :: [String] -> [ByteString] -> [ByteString]
buildDList texts = foldr (\t acc -> emit openTag . emitEscaped t . emit closeTag . acc) id texts
  where
    emit b = (b :)
    emitEscaped t = (escapeBytes (BS.pack t) :)

-- A chunk tree (rope): O(1) append by node construction.

data Rope = REmpty | RLeaf ByteString | RNode Rope Rope

buildRope :: [String] -> Rope
buildRope = foldr (\t acc -> RNode (row t) acc) REmpty
  where
    row t = RNode (RLeaf openTag) (RNode (RLeaf (escapeBytes (BS.pack t))) (RLeaf closeTag))

-- | Flattens a rope to a chunk list using an accumulator (no concatenation).
ropeToList :: Rope -> [ByteString] -> [ByteString]
ropeToList REmpty acc = acc
ropeToList (RLeaf b) acc = b : acc
ropeToList (RNode l r) acc = ropeToList l (ropeToList r acc)

-- | Sums the lengths of a chunk list, modelling a per-chunk socket write.
sumLengths :: [ByteString] -> Int
sumLengths = foldl' (\acc b -> acc + BS.length b) 0

{- | Packs a chunk list into segments of at least @bufSize@ bytes, modelling a
blaze-style buffer-filling builder: many small fragments become few large
writes, in one O(n) pass.
-}
coalesce :: Int -> [ByteString] -> [ByteString]
coalesce bufSize chunks =
    finish (foldl' step ([], [], 0) chunks)
  where
    step (out, cur, len) c
        | len >= bufSize = (BS.concat (reverse cur) : out, [c], BS.length c)
        | otherwise = (out, c : cur, len + BS.length c)
    finish (out, cur, _) =
        reverse (if null cur then out else BS.concat (reverse cur) : out)

-- Socket-write measurement: how many sendAll calls a page costs in practice.

{- | Times sending a page as a chunk list across `socketReps` rounds, draining
each round, and reports sends/page (the chunk count) and wall time per page.
-}
socketBench :: String -> ClientSocket -> ClientSocket -> [ByteString] -> IO ()
socketBench name client served chunks = do
    let total = sumLengths chunks
    t0 <- getCPUTime
    mapM_ (const (sendPage client served chunks total)) [1 .. socketReps]
    t1 <- getCPUTime
    let secs = fromIntegral (t1 - t0) / 1.0e12 :: Double
        usEach = secs * 1.0e6 / fromIntegral socketReps
    putStrLn
        ( pad 13 name
            ++ "| "
            ++ pad 10 (show (length chunks))
            ++ " | "
            ++ pad 8 (showFixed (secs * 1000.0))
            ++ " | "
            ++ showFixed usEach
        )

-- | Sends every chunk of a page (one sendAll each), then drains the total.
sendPage :: ClientSocket -> ClientSocket -> [ByteString] -> Int -> IO ()
sendPage client served chunks total = do
    mapM_ sendOne chunks
    drain served total
  where
    sendOne c = sendAll client c >>= either (\err -> error ("sendAll failed: " ++ show err)) return

-- | Reads exactly @total@ bytes from the socket in recvBuf-sized reads.
drain :: ClientSocket -> Int -> IO ()
drain sock total
    | total <= 0 = return ()
    | otherwise = do
        received <- recv sock recvBuf
        case received of
            Left err -> error ("recv failed: " ++ show err)
            Right bytes
                | BS.null bytes -> error "recv returned end of stream mid-transfer"
                | otherwise -> drain sock (total - BS.length bytes)

-- | A connected loopback socket pair, mirroring bench/SocketBench.hs.
withConnectedPair :: (ClientSocket -> ClientSocket -> IO ()) -> IO ()
withConnectedPair use = do
    opened <- listenTcp HostAny (Port 0) 1
    case opened of
        Left err -> error ("listenTcp failed: " ++ show err)
        Right socket -> do
            queried <- boundPort socket
            case queried of
                Left err -> error ("boundPort failed: " ++ show err)
                Right port -> do
                    connected <- connectTcp (HostIPv4 127 0 0 1) port
                    case connected of
                        Left err -> error ("connectTcp failed: " ++ show err)
                        Right client -> do
                            accepted <- accept socket
                            case accepted of
                                Left err -> error ("accept failed: " ++ show err)
                                Right (served, _info) -> do
                                    use client served
                                    _ <- closeClientSocket served
                                    _ <- closeClientSocket client
                                    return ()
            _ <- closeListenSocket socket
            return ()

-- | HTML-escapes a ByteString, sharing the replacement fragments as CAFs.
escapeBytes :: ByteString -> ByteString
escapeBytes = BS.concatMap esc
  where
    esc '<' = ltBytes
    esc '>' = gtBytes
    esc '&' = ampBytes
    esc '"' = quotBytes
    esc '\'' = aposBytes
    esc c = BS.singleton c

ltBytes, gtBytes, ampBytes, quotBytes, aposBytes :: ByteString
ltBytes = BS.pack "&lt;"
gtBytes = BS.pack "&gt;"
ampBytes = BS.pack "&amp;"
quotBytes = BS.pack "&quot;"
aposBytes = BS.pack "&#39;"

-- | Packs a constant literal on every call (the anti-pattern).
packEach :: Int -> Int
packEach _ = BS.length (BS.pack "<li class=\"row\">")

-- | References a shared, pre-packed constant.
sharedCaf :: Int -> Int
sharedCaf _ = BS.length openTag

-- Small formatting helpers (no Text.Printf under mhs).

pad :: Int -> String -> String
pad n s = s ++ replicate (max 0 (n - length s)) ' '

showFixed :: Double -> String
showFixed x =
    let scaled = round (x * 1000.0) :: Integer
        whole = scaled `div` 1000
        frac = scaled `mod` 1000
        fracDigits = show frac
        fracText = replicate (3 - length fracDigits) '0' ++ fracDigits
     in show whole ++ "." ++ fracText
