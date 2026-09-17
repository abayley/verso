{- | The per-chunk cost of a streaming consumer, in process, with no socket and
no file (RFC-0050 phase 1).

RFC-0050 asks whether expressing the five hand-written consumers in terms of a
shared fold and a shared cap costs more than the duplication is worth. Under
MicroHs each combinator is a dictionary and an allocation per chunk
(@docs/architecture/streaming-algebra.md@), and these consumers carry every
request body and every file read, so the question is the cost of one chunk
passing through one more layer.

That is why nothing here touches I/O. @make bench-iteratee@ drives a saturated
socket and @make bench-egress@ a send path; in both, syscalls dominate and would
hide a per-chunk regression rather than expose it, which would make the gate
falsely permissive. Here a consumer is fed a fixed list of chunks already in
memory, so what is timed is the loop.

Chunk sizes bracket the real ones: 64 bytes is far smaller than the stream ever
delivers and exaggerates per-chunk cost on purpose, 4096 is the decoder slice,
and 16384 is a socket read. The same total number of bytes moves at every size,
so the columns are comparable and the difference between them is per-chunk
overhead rather than throughput.
-}
module Main (main) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Iteratee as Iteratee
import qualified System.CPUTime as CPUTime

main :: IO ()
main = do
    putStrLn ("total " ++ show (totalBytes `div` 1024) ++ " KB per run, best of " ++ show reps)
    putStrLn "consumer          | chunk | chunks |  best ms |   ns/chunk"
    mapM_ (row "byteSinkI" totalBytes runByteSink) chunkSizes
    mapM_ (row "handSink (before)" totalBytes runHandSink) chunkSizes
    mapM_ (row "capped byteSinkI" totalBytes runCappedSink) chunkSizes
    mapM_ (row "inline-cap sink" totalBytes runInlineCapSink) chunkSizes
    putStrLn ("total " ++ show (collectedBytes `div` 1024) ++ " KB per run for the collector")
    mapM_ (row "readBodyStrict" collectedBytes runReadBody) chunkSizes
    mapM_ (row "readBody via fold" collectedBytes runReadBodyFolded) chunkSizes

-- | Bytes moved per run, the same at every chunk size.
totalBytes :: Int
totalBytes = 8 * 1024 * 1024

{- | The collector gets less, because it is the one consumer that holds what it
has seen: it keeps a list of every chunk and concatenates at the end, and at the
8 MB above, split into 64-byte chunks, that list is long enough to exhaust the
MicroHs evaluator stack outright (@ERR: stack overflow@, 131072 chunks). That is
a real limit of 'Iteratee.readBodyStrict', not of this bench -- its own Haddock
warns the final concat is O(total * pieces) -- but it is a property of the
consumer as it stands, so timing it needs an input it survives.
-}
collectedBytes :: Int
collectedBytes = 1024 * 1024

reps :: Int
reps = 9

chunkSizes :: [Int]
chunkSizes = [64, 4096, 16384]

row :: String -> Int -> ([BS.ByteString] -> IO Int) -> Int -> IO ()
row name bytes consume size = do
    let chunks = chunksOf bytes size
        count = length chunks
    best <- bestOf reps (consume chunks)
    let ms = best * 1000
        nsPerChunk = best * 1000000000 / fromIntegral count
    putStrLn
        ( pad 17 name
            ++ " | "
            ++ pad 5 (show size)
            ++ " | "
            ++ pad 6 (show count)
            ++ " | "
            ++ pad 8 (showTo2 ms)
            ++ " | "
            ++ showTo2 nsPerChunk
        )

-- | The chunks one run feeds: that many bytes split into pieces of this size.
chunksOf :: Int -> Int -> [BS.ByteString]
chunksOf bytes size = replicate (bytes `div` size) (BS.replicate size 'x')

{- | The best wall of @n@ runs. Best rather than mean: the question is the cost
of the code, and a slower run only means the machine was busy.
-}
bestOf :: Int -> IO Int -> IO Double
bestOf n action = go n (1 / 0)
  where
    go 0 best = pure best
    go k best = do
        start <- CPUTime.getCPUTime
        result <- action
        -- Forced before the end time is read, or the work moves after it.
        end <- result `seq` CPUTime.getCPUTime
        let elapsed = fromIntegral (end - start) / 1000000000000
        go (k - 1 :: Int) (min best elapsed)

{- | A sink whose writer only counts, so what is timed is the consumer's loop
rather than the writer's work. The counter is an 'IORef' because a real writer
has an effect; a pure step would flatter the fold.
-}
runByteSink :: [BS.ByteString] -> IO Int
runByteSink chunks = do
    counter <- IORef.newIORef (0 :: Int)
    let sink = Iteratee.byteSinkI (\bytes -> IORef.modifyIORef' counter (+ BS.length bytes) >> pure (Right ()))
    outcome <- feedAll chunks (sink :: Iteratee.Iter String ())
    case outcome of
        Left err -> error ("byteSinkI failed: " ++ err)
        Right () -> IORef.readIORef counter

{- | The loop 'Iteratee.byteSinkI' had before RFC-0050 expressed it through
'Iteratee.foldChunksI', kept here to price the layer rather than to be used. The
difference between this row and the @byteSinkI@ one is what the shared fold
costs per chunk; the difference to @capped byteSinkI@ is what a second combinator
costs on top.
-}
runHandSink :: [BS.ByteString] -> IO Int
runHandSink chunks = do
    counter <- IORef.newIORef (0 :: Int)
    outcome <- feedAll chunks (handSink (\bytes -> IORef.modifyIORef' counter (+ BS.length bytes) >> pure (Right ())) :: Iteratee.Iter String ())
    case outcome of
        Left err -> error ("handSink failed: " ++ err)
        Right () -> IORef.readIORef counter

handSink :: (BS.ByteString -> IO (Either e ())) -> Iteratee.Iter e ()
handSink writeBytes = go
  where
    go = Iteratee.NeedInput consume
    consume s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> go
            | otherwise -> Iteratee.IterM (fmap afterWrite (writeBytes bytes))
        Iteratee.EndOfStream Nothing -> Iteratee.Done () (Iteratee.EndOfStream Nothing)
        Iteratee.EndOfStream (Just err) -> Iteratee.IterFailed err (Iteratee.EndOfStream (Just err))
    afterWrite sent = case sent of
        Left err -> Iteratee.IterFailed err (Iteratee.Chunk BS.empty)
        Right () -> go

{- | The cap as a wrapper: the shape RFC-0050 proposed and phase 1 rejected, at
2.40x the hand-written loop against the shared fold's 1.17x. It lives here rather
than in the library because nothing should use it; the row is kept so the number
that rejected it stays reproducible.
-}
cappedI :: Int -> e -> Iteratee.Iter e a -> Iteratee.Iter e a
cappedI limit tooLarge = go 0
  where
    go seen inner = case inner of
        Iteratee.NeedInput _ -> Iteratee.NeedInput (step seen inner)
        Iteratee.IterM m -> Iteratee.IterM (fmap (go seen) m)
        other -> other
    step seen inner s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> go seen inner
            | seen + BS.length bytes > limit -> Iteratee.IterFailed tooLarge (Iteratee.Chunk bytes)
            | otherwise -> Iteratee.IterM (fmap (go (seen + BS.length bytes)) (Iteratee.feedChunk bytes inner))
        end -> case inner of
            Iteratee.NeedInput k -> k end
            other -> other

-- | The same sink behind that wrapper: the cost of one more combinator.
runCappedSink :: [BS.ByteString] -> IO Int
runCappedSink chunks = do
    counter <- IORef.newIORef (0 :: Int)
    let sink = Iteratee.byteSinkI (\bytes -> IORef.modifyIORef' counter (+ BS.length bytes) >> pure (Right ()))
    outcome <- feedAll chunks (cappedI (totalBytes * 2) "too large" sink :: Iteratee.Iter String ())
    case outcome of
        Left err -> error ("capped byteSinkI failed: " ++ err)
        Right () -> IORef.readIORef counter

{- | The same cap checked inside the fold rather than wrapped around it: the
accumulator carries the running count, so there is no second consumer for a chunk
to pass through. If this costs what the uncapped fold costs, then the cap is
cheap to share and only its packaging as a combinator is expensive.
-}
runInlineCapSink :: [BS.ByteString] -> IO Int
runInlineCapSink chunks = do
    counter <- IORef.newIORef (0 :: Int)
    let limit = totalBytes * 2
        step seen bytes
            | seen + BS.length bytes > limit = pure (Left "too large")
            | otherwise = do
                IORef.modifyIORef' counter (+ BS.length bytes)
                pure (Right (seen + BS.length bytes))
    outcome <- feedAll chunks (Iteratee.foldChunksI step (0 :: Int) :: Iteratee.Iter String Int)
    case outcome of
        Left err -> error ("inline-cap sink failed: " ++ err)
        Right _ -> IORef.readIORef counter

-- | The capped collector, which is the cap's cost as well as the loop's.
runReadBody :: [BS.ByteString] -> IO Int
runReadBody chunks = do
    outcome <- feedAll chunks (Iteratee.readBodyStrict "too large" (collectedBytes * 2) :: Iteratee.Iter String BS.ByteString)
    case outcome of
        Left err -> error ("readBodyStrict failed: " ++ err)
        Right bytes -> pure (BS.length bytes)

{- | 'Iteratee.readBodyStrict' expressed through the shared fold, to price what
that would cost. The consumer's step is pure today -- it only conses a chunk onto
a list -- so folding it adds an 'Iteratee.IterM' per chunk where there is none,
which is the cost this row isolates. It is here rather than in the library
because RFC-0050 phase 3 declined the change.
-}
runReadBodyFolded :: [BS.ByteString] -> IO Int
runReadBodyFolded chunks = do
    let limit = collectedBytes * 2
        step (seen, acc) bytes
            | seen + BS.length bytes > limit = pure (Left "too large")
            | otherwise = pure (Right (seen + BS.length bytes, bytes : acc))
    outcome <- feedAll chunks (Iteratee.foldChunksI step (0 :: Int, []) :: Iteratee.Iter String (Int, [BS.ByteString]))
    case outcome of
        Left err -> error ("readBody via fold failed: " ++ err)
        Right (_, acc) -> pure (BS.length (BS.concat (reverse acc)))

-- | Feeds every chunk, then ends the stream, as an enumerator would.
feedAll :: [BS.ByteString] -> Iteratee.Iter e a -> IO (Either e a)
feedAll chunks it0 = go chunks it0 >>= Iteratee.run
  where
    go [] it = pure it
    go (c : cs) it = Iteratee.feedChunk c it >>= go cs

showTo2 :: Double -> String
showTo2 x = show (fromIntegral (round (x * 100) :: Int) / 100 :: Double)

pad :: Int -> String -> String
pad n s = s ++ replicate (max 0 (n - length s)) ' '
