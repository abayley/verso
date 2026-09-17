module MicroHttp.IterateeSpec (spec) where

import qualified Control.Exception as Exception
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified Data.IORef as IORef
import qualified MicroHttp.Iteratee as Iteratee
import Test.Hspec
import qualified TestSupport.Iteratee as Support

{- | A domain-free error type, proving the core carries no HTTP or socket
vocabulary of its own.
-}
data TestError
    = TooLarge
    | Boom
    | Incomplete
    deriving (Eq, Show)

spec :: Spec
spec =
    describe "MicroHttp.Iteratee" $ do
        it "given a bind across a chunk boundary, when the first iteratee finishes mid-chunk, then the second receives the residue" $ do
            (result, _) <- drive ["AAABBB"] (pair (takeExactly 3) (takeExactly 3))
            result `shouldBe` Right (BS.pack "AAA", BS.pack "BBB")
        it "given a bind whose residue alone completes the second iteratee, when it runs, then the enumerator is not asked for more input" $ do
            (result, pulls) <- drive ["AAABBB"] (pair (takeExactly 3) (takeExactly 3))
            result `shouldBe` Right (BS.pack "AAA", BS.pack "BBB")
            pulls `shouldBe` 1
        it "given an empty chunk fed to a waiting consumer, when it continues, then the empty chunk is not treated as end of stream" $ do
            (result, _) <- drive ["", "ABC"] (takeExactly 3)
            result `shouldBe` Right (BS.pack "ABC")
        it "given end of stream delivered twice, when an iteratee has resolved, then the result is stable" $ do
            let once = step (Iteratee.EndOfStream Nothing) collectAll
                twice = step (Iteratee.EndOfStream Nothing) once
            isDone once `shouldBe` True
            extract once `shouldBe` extract twice
            extract twice `shouldBe` Right (BS.pack "")
        it "given end of stream, when a consumer needs more input, then it resolves to a failure rather than NeedInput" $ do
            let result = step (Iteratee.EndOfStream Nothing) (takeExactly 5)
            isFailed result `shouldBe` True
            isNeedInput result `shouldBe` False
        it "given a failing iteratee, when it fails mid-chunk, then IterFailed carries the unconsumed residue" $ do
            let result = step (Iteratee.Chunk (BS.pack "LEFTOVER")) failOnInput
            residueOf result `shouldBe` Just (Iteratee.Chunk (BS.pack "LEFTOVER"))
        it "given chunks, when folded, then the step sees each in order and the accumulator is returned" $ do
            (result, _) <- drive ["ab", "cd", "ef"] (collectFold 100)
            fmap reverse result `shouldBe` Right [BS.pack "ab", BS.pack "cd", BS.pack "ef"]
        it "given an empty chunk, when folded, then the step is not called for it" $ do
            -- The line fold's step indexes into the chunk it is handed, so an
            -- empty one reaching a step would be a crash, not a wrong answer.
            (result, _) <- drive ["ab", "", "cd"] (collectFold 100)
            fmap reverse result `shouldBe` Right [BS.pack "ab", BS.pack "cd"]
        it "given a step that fails, when folded, then the consumer fails with that error and an empty residue" $ do
            -- fed rather than stepped: the step runs in IO, so the consumer is an
            -- IterM until something resolves it.
            failed <- Iteratee.feedChunk (BS.pack "abc") (collectFold 0)
            residueOf failed `shouldBe` Just (Iteratee.Chunk BS.empty)
            isFailed failed `shouldBe` True
        it "given a failed end of stream, when folded, then the failure propagates with the end as residue" $ do
            let ended = step (Iteratee.EndOfStream (Just Boom)) (collectFold 100)
            residueOf ended `shouldBe` Just (Iteratee.EndOfStream (Just Boom))
        it "given no chunks at all, when folded, then the initial accumulator is returned" $ do
            (result, _) <- drive [] (collectFold 100)
            result `shouldBe` Right []
        it "given a body within the bound, when reading strictly, then the whole body is returned" $ do
            (result, _) <- drive ["hello", " world"] (Iteratee.readBodyStrict TooLarge 100)
            result `shouldBe` Right (BS.pack "hello world")
        it "given a bound below the body size, when reading strictly, then the iteratee fails with the supplied error" $ do
            (result, _) <- drive ["hello", " world"] (Iteratee.readBodyStrict TooLarge 3)
            result `shouldBe` Left TooLarge
        it "given a takeN bound, when the inner iteratee consumes, then it sees exactly n bytes and outer residue is preserved" $ do
            (result, _) <- drive ["AAAAABBB"] (pair (Iteratee.takeN 5 collectAll) collectAll)
            result `shouldBe` Right (BS.pack "AAAAA", BS.pack "BBB")
        it "given a takeN bound, when the inner iteratee completes early, then the unread remainder stays in the outer residue" $ do
            (result, _) <- drive ["AAABBBBBB"] (pair (Iteratee.takeN 10 (takeExactly 3)) collectAll)
            result `shouldBe` Right (BS.pack "AAA", BS.pack "BBBBBB")
        it "given a strict enumerator, when run into a collecting consumer, then the value round-trips" $ do
            final <- Iteratee.strictEnumerator (BS.pack "payload bytes") (Iteratee.readBodyStrict TooLarge 1000)
            result <- Iteratee.run final
            result `shouldBe` Right (BS.pack "payload bytes")
        it "given a bracketed resource enumerator, when the consumer completes, then the resource is released exactly once" $ do
            (acquire, release, readChunk, closeCount) <- fakeResource ["AB", "CD"]
            final <- Iteratee.resourceEnumerator acquire release readChunk Boom (Iteratee.readBodyStrict TooLarge 1000)
            result <- Iteratee.run final
            result `shouldBe` Right (BS.pack "ABCD")
            closeCount `shouldReturn` 1
        it "given a bracketed resource enumerator, when the consumer fails mid-stream, then the resource is still released" $ do
            (acquire, release, readChunk, closeCount) <- fakeResource ["AB", "CD"]
            final <- Iteratee.resourceEnumerator acquire release readChunk Boom failOnInput
            result <- Iteratee.run final
            isLeft result `shouldBe` True
            closeCount `shouldReturn` 1
        it "given a bracketed resource enumerator, when the consumer stops early, then the resource is released" $ do
            (acquire, release, readChunk, closeCount) <- fakeResource ["AAAA", "BBBB"]
            final <- Iteratee.resourceEnumerator acquire release readChunk Boom (Iteratee.takeN 2 (Iteratee.readBodyStrict TooLarge 1000))
            result <- Iteratee.run final
            result `shouldBe` Right (BS.pack "AA")
            closeCount `shouldReturn` 1
        it "given a resource that fails to acquire, when enumerated, then the consumer sees the acquire error and nothing is released" $ do
            (_, release, readChunk, closeCount) <- fakeResource ["AB"]
            final <- Iteratee.resourceEnumerator (return Nothing) release readChunk Boom (Iteratee.readBodyStrict TooLarge 1000)
            result <- Iteratee.run final
            result `shouldBe` Left Boom
            closeCount `shouldReturn` 0
        it "given a failure cleanup, when the consumer completes, then the cleanup does not run" $ do
            ran <- IORef.newIORef (0 :: Int)
            final <- Iteratee.strictEnumerator (BS.pack "ok") (Iteratee.onFailure (IORef.modifyIORef ran (+ 1)) (Iteratee.readBodyStrict TooLarge 1000))
            result <- Iteratee.run final
            result `shouldBe` Right (BS.pack "ok")
            IORef.readIORef ran `shouldReturn` 0
        it "given a failure cleanup, when the consumer fails on input, then the cleanup runs once and the failure propagates" $ do
            ran <- IORef.newIORef (0 :: Int)
            final <- Iteratee.strictEnumerator (BS.pack "boom") (Iteratee.onFailure (IORef.modifyIORef ran (+ 1)) failOnInput)
            result <- Iteratee.run final
            result `shouldBe` Left Boom
            IORef.readIORef ran `shouldReturn` 1
        it "given a failure cleanup, when the stream fails at its end, then the cleanup runs" $ do
            ran <- IORef.newIORef (0 :: Int)
            let waiting = Iteratee.onFailure (IORef.modifyIORef ran (+ 1)) (Iteratee.readBodyStrict TooLarge 1000)
            fed <- Iteratee.feedChunk (BS.pack "partial") waiting
            result <- Iteratee.run (case fed of Iteratee.NeedInput k -> k (Iteratee.EndOfStream (Just Boom)); other -> other)
            result `shouldBe` Left Boom
            IORef.readIORef ran `shouldReturn` 1
        it "given a failure cleanup, when an effect step throws, then the cleanup runs once and the exception propagates" $ do
            ran <- IORef.newIORef (0 :: Int)
            let throwing = Iteratee.IterM (Exception.throwIO (userError "disk full")) :: Iteratee.Iter TestError ()
            outcome <- Exception.try (Iteratee.run (Iteratee.onFailure (IORef.modifyIORef ran (+ 1)) throwing))
            either (\e -> "threw: " ++ show (e :: Exception.SomeException)) (const "completed") outcome `shouldBe` "threw: user error (disk full)"
            IORef.readIORef ran `shouldReturn` 1
        it "given a lifted base action, when the iteratee runs, then its result is the action's and the stream is untouched (RFC-0041)" $ do
            final <- Iteratee.strictEnumerator (BS.pack "abc") (pair (Iteratee.lift (pure (5 :: Int))) Iteratee.headChunk :: Iteratee.Iter TestError (Int, Maybe BS.ByteString))
            result <- Iteratee.run final
            result `shouldBe` Right (5, Just (BS.pack "abc"))
        it "given a two-layer consumer, when each layer is fed by its own enumerator, then it reads one chunk from each (RFC-0041)" $ do
            outcome <- Iteratee.runNested2 (Iteratee.strictEnumerator (BS.pack "A")) (Iteratee.strictEnumerator (BS.pack "B")) headOfEach
            outcome `shouldBe` Right (Just (BS.pack "A"), Just (BS.pack "B"))
        it "given a two-layer consumer whose inner stream is empty, when it reads both, then it sees the inner end and still reads the outer chunk (RFC-0041)" $ do
            outcome <- Iteratee.runNested2 (Iteratee.strictEnumerator BS.empty) (Iteratee.strictEnumerator (BS.pack "B")) headOfEach
            outcome `shouldBe` Right (Nothing, Just (BS.pack "B"))
        it "given a failure delivered at the inner layer, when the two layers are run, then it surfaces as the single outcome (RFC-0041)" $ do
            outcome <- Iteratee.runNested2 (failingEnumerator Boom) (Iteratee.strictEnumerator (BS.pack "B")) headOfEach
            outcome `shouldBe` Left Boom
        it "given a failure delivered at the base layer, when the two layers are run, then it surfaces as the single outcome (RFC-0041)" $ do
            outcome <- Iteratee.runNested2 (Iteratee.strictEnumerator (BS.pack "A")) (failingEnumerator Boom) headOfEach
            outcome `shouldBe` Left Boom
        it "given a bracketed resource enumerator feeding the inner layer, when the two-source consumer completes early, then the resource is released exactly once (RFC-0041)" $ do
            (acquire, release, readChunk, closes) <- fakeResource ["one", "two", "three"]
            outcome <- Iteratee.runNested2 (Iteratee.resourceEnumerator acquire release readChunk Boom) (Iteratee.strictEnumerator (BS.pack "B")) headOfEach
            outcome `shouldBe` Right (Just (BS.pack "one"), Just (BS.pack "B"))
            closes `shouldReturn` 1
        it "given a bracketed resource enumerator feeding the inner layer, when the consumer fails mid-stream, then the resource is released exactly once (RFC-0041)" $ do
            (acquire, release, readChunk, closes) <- fakeResource ["one", "two"]
            let failAfterOne = Iteratee.headChunk >> Iteratee.IterFailed Boom (Iteratee.Chunk BS.empty) :: Iteratee.IterT TestError (Iteratee.IterT TestError IO) ()
            outcome <- Iteratee.runNested2 (Iteratee.resourceEnumerator acquire release readChunk TooLarge) (Iteratee.strictEnumerator (BS.pack "B")) failAfterOne
            outcome `shouldBe` Left Boom
            closes `shouldReturn` 1
        it "given a bracketed resource enumerator feeding the inner layer, when the outer stream fails, then the failure is the outcome and the inner resource is released exactly once (RFC-0041 review)" $ do
            (acquire, release, readChunk, closes) <- fakeResource ["one", "two"]
            outcome <- Iteratee.runNested2 (Iteratee.resourceEnumerator acquire release readChunk TooLarge) (failingEnumerator Boom) headOfEach
            outcome `shouldBe` Left Boom
            closes `shouldReturn` 1
        it "given a bracketed resource enumerator feeding the outer layer, when the inner consumer fails after reading both, then the outer resource is released exactly once (RFC-0041 review)" $ do
            (acquire, release, readChunk, closes) <- fakeResource ["one", "two"]
            let failAfterBoth = headOfEach >> Iteratee.IterFailed Boom (Iteratee.Chunk BS.empty) :: Iteratee.IterT TestError (Iteratee.IterT TestError IO) ()
            outcome <- Iteratee.runNested2 (Iteratee.strictEnumerator (BS.pack "A")) (Iteratee.resourceEnumerator acquire release readChunk TooLarge) failAfterBoth
            outcome `shouldBe` Left Boom
            closes `shouldReturn` 1
        it "given an outer resource that fails to acquire, when the two layers are run, then the acquire error is the outcome and the inner resource is released (RFC-0041 review)" $ do
            (acquire, release, readChunk, closes) <- fakeResource ["one", "two"]
            (_, outerRelease, outerRead, outerCloses) <- fakeResource ["B"]
            outcome <- Iteratee.runNested2 (Iteratee.resourceEnumerator acquire release readChunk TooLarge) (Iteratee.resourceEnumerator (pure Nothing) outerRelease outerRead Boom) headOfEach
            outcome `shouldBe` Left Boom
            closes `shouldReturn` 1
            outerCloses `shouldReturn` 0
        it "given a chunk transformer with a carry, when chunks split the carried byte from its successor, then the inner sink sees the rejoined, transformed bytes (RFC-0043)" $ do
            (result, _) <- drive ["abx", "cd"] (Iteratee.mapChunksI upperKeepingTrailingX id collectAll)
            result `shouldBe` Right (BS.pack "ABXCD")
        it "given a chunk transformer with a carry, when the stream ends with bytes carried, then finish flushes them before the inner sink's end (RFC-0043)" $ do
            (result, _) <- drive ["abx"] (Iteratee.mapChunksI upperKeepingTrailingX id collectAll)
            result `shouldBe` Right (BS.pack "ABx")
        it "given a chunk transformer, when the inner sink completes early, then the transformer stops feeding and returns it (RFC-0043)" $ do
            final <- Iteratee.strictEnumerator (BS.pack "abcdef") (Iteratee.mapChunksI upperKeepingTrailingX id (takeExactly 2))
            Iteratee.run final `shouldReturn` Right (BS.pack "AB")
        it "given a line transformer, when lines straddle chunk boundaries, then the inner sink sees one terminated line per chunk and the last unterminated line at the end (RFC-0043)" $ do
            (result, _) <- drive ["ab\ncd", "ef\n\ngh"] (Iteratee.linesI chunksI)
            result `shouldBe` Right (map BS.pack ["ab\n", "cdef\n", "\n", "gh"])
        it "given a line transformer, when a line ends in CRLF, then the carriage return stays with its line (RFC-0043)" $ do
            (result, _) <- drive ["a\r", "\nb\n"] (Iteratee.linesI chunksI)
            result `shouldBe` Right (map BS.pack ["a\r\n", "b\n"])
        it "given a line transformer, when the stream fails, then the failure reaches the inner sink (RFC-0043)" $ do
            outcome <- failingEnumerator Boom (Iteratee.linesI chunksI) >>= Iteratee.run
            outcome `shouldBe` Left Boom
        it "given several sources appended, when one consumer reads them, then it sees their bytes in order and one end of stream (RFC-0043)" $ do
            final <- Iteratee.appendEnumerators (map (Iteratee.strictEnumerator . BS.pack) ["ab", "cd", "ef"]) (Iteratee.readBodyStrict TooLarge 1000)
            Iteratee.run final `shouldReturn` Right (BS.pack "abcdef")
        it "given several bracketed sources appended, when the consumer completes during the first, then the later sources are never opened and the first is released (RFC-0043)" $ do
            (acquireA, releaseA, readA, closesA) <- fakeResource ["AAAA", "AAAA"]
            (acquireB, releaseB, readB, closesB) <- fakeResource ["BBBB"]
            let sources = [Iteratee.resourceEnumerator acquireA releaseA readA Boom, Iteratee.resourceEnumerator acquireB releaseB readB Boom]
            final <- Iteratee.appendEnumerators sources (Iteratee.takeN 2 (Iteratee.readBodyStrict TooLarge 1000))
            Iteratee.run final `shouldReturn` Right (BS.pack "AA")
            closesA `shouldReturn` 1
            closesB `shouldReturn` 0
        it "given several sources appended, when the first fails, then the failure is the outcome and the rest are not read (RFC-0043)" $ do
            (acquireB, releaseB, readB, closesB) <- fakeResource ["BBBB"]
            final <- Iteratee.appendEnumerators [failingEnumerator Boom, Iteratee.resourceEnumerator acquireB releaseB readB Boom] (Iteratee.readBodyStrict TooLarge 1000)
            Iteratee.run final `shouldReturn` Left Boom
            closesB `shouldReturn` 0
        it "given a waiting consumer, when fed chunks without an end of stream, then it holds them and completes on the later end" $ do
            fed <- Iteratee.feedChunk (BS.pack "ab") (Iteratee.readBodyStrict TooLarge 1000 :: Iteratee.Iter TestError BS.ByteString)
            fed' <- Iteratee.feedChunk (BS.pack "cd") fed
            final <- Iteratee.strictEnumerator BS.empty fed'
            result <- Iteratee.run final
            result `shouldBe` Right (BS.pack "abcd")
        it "given a completed consumer, when fed a chunk, then it passes through unchanged with its residue" $ do
            let done = Iteratee.Done (BS.pack "value") (Iteratee.Chunk (BS.pack "rest")) :: Iteratee.Iter TestError BS.ByteString
            fed <- Iteratee.feedChunk (BS.pack "more") done
            result <- Iteratee.run fed
            result `shouldBe` Right (BS.pack "value")
        it "given a failed consumer, when fed a chunk, then the failure passes through" $ do
            fed <- Iteratee.feedChunk (BS.pack "x") (Iteratee.IterFailed Boom (Iteratee.Chunk BS.empty) :: Iteratee.Iter TestError ())
            result <- Iteratee.run fed
            result `shouldBe` Left Boom
        it "given an effect step, when fed a chunk, then the effect is resolved before the chunk is delivered" $ do
            ran <- IORef.newIORef False
            let stepped = Iteratee.IterM (IORef.writeIORef ran True >> return (Iteratee.readBodyStrict TooLarge 1000)) :: Iteratee.Iter TestError BS.ByteString
            fed <- Iteratee.feedChunk (BS.pack "hi") stepped
            IORef.readIORef ran `shouldReturn` True
            final <- Iteratee.strictEnumerator BS.empty fed
            result <- Iteratee.run final
            result `shouldBe` Right (BS.pack "hi")
        it "given an empty chunk, when fed, then the consumer is left waiting rather than read as end of stream" $ do
            fed <- Iteratee.feedChunk BS.empty (Iteratee.readBodyStrict TooLarge 1000 :: Iteratee.Iter TestError BS.ByteString)
            final <- Iteratee.strictEnumerator (BS.pack "late") fed
            result <- Iteratee.run final
            result `shouldBe` Right (BS.pack "late")

-- Test-local consumers, built from the exported Iter constructors.

-- | A block step for the transformer cases: upper-cases the block, carrying a trailing @x@ into the next block.
upperKeepingTrailingX :: BS.ByteString -> (BS.ByteString, BS.ByteString)
upperKeepingTrailingX block
    | not (BS.null block) && BS.last block == 'x' = (BS.map Char.toUpper (BS.init block), BS.pack "x")
    | otherwise = (BS.map Char.toUpper block, BS.empty)

-- | Collects each chunk as delivered, so a transformer's chunking is observable.
chunksI :: Iteratee.Iter TestError [BS.ByteString]
chunksI = go []
  where
    go acc = Iteratee.NeedInput (consume acc)
    consume acc s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> go acc
            | otherwise -> go (bytes : acc)
        Iteratee.EndOfStream Nothing -> Iteratee.Done (reverse acc) s
        Iteratee.EndOfStream (Just err) -> Iteratee.IterFailed err s

-- | The shared two-source consumer, pinned to the spec's error type.
headOfEach :: Iteratee.IterT TestError (Iteratee.IterT TestError IO) (Maybe BS.ByteString, Maybe BS.ByteString)
headOfEach = Support.headOfEach

-- | An enumerator that delivers a failed end of stream at once, at whatever layer it is used.
failingEnumerator :: (Monad m) => e -> Iteratee.EnumeratorT e m a
failingEnumerator err it = case it of
    Iteratee.NeedInput k -> pure (k (Iteratee.EndOfStream (Just err)))
    Iteratee.IterM m -> m >>= failingEnumerator err
    other -> pure other

{- | Reads exactly @total@ bytes, keeping any surplus as residue; fails if the
stream ends first.
-}
takeExactly :: Int -> Iteratee.Iter TestError BS.ByteString
takeExactly total = go total []
  where
    go remaining acc
        | remaining <= 0 = Iteratee.Done (BS.concat (reverse acc)) (Iteratee.Chunk BS.empty)
        | otherwise = Iteratee.NeedInput (consume remaining acc)
    consume remaining acc s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> go remaining acc
            | BS.length bytes <= remaining -> go (remaining - BS.length bytes) (bytes : acc)
            | otherwise ->
                let (taken, rest) = BS.splitAt remaining bytes
                 in Iteratee.Done (BS.concat (reverse (taken : acc))) (Iteratee.Chunk rest)
        Iteratee.EndOfStream merr -> Iteratee.IterFailed (incompleteError merr) (Iteratee.EndOfStream merr)

-- | Reads to end of stream, returning the concatenation.
collectAll :: Iteratee.Iter TestError BS.ByteString
collectAll = go []
  where
    go acc = Iteratee.NeedInput (consume acc)
    consume acc s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> go acc
            | otherwise -> go (bytes : acc)
        Iteratee.EndOfStream _ -> Iteratee.Done (BS.concat (reverse acc)) (Iteratee.EndOfStream Nothing)

-- | Fails on the first input, keeping it as residue.
failOnInput :: Iteratee.Iter TestError ()
failOnInput = Iteratee.NeedInput consume
  where
    consume s = case s of
        Iteratee.Chunk bytes -> Iteratee.IterFailed Boom (Iteratee.Chunk bytes)
        Iteratee.EndOfStream merr -> Iteratee.IterFailed (incompleteError merr) (Iteratee.EndOfStream merr)

incompleteError :: Maybe TestError -> TestError
incompleteError (Just err) = err
incompleteError Nothing = Incomplete

pair :: Iteratee.Iter e a -> Iteratee.Iter e b -> Iteratee.Iter e (a, b)
pair left right = do
    a <- left
    b <- right
    pure (a, b)

{- | A recording fake resource: it serves the scripted chunks then empty,
and counts release calls so bracketing is observable without real files or
reliance on garbage collection.
-}
fakeResource :: [String] -> IO (IO (Maybe ()), () -> IO (), () -> IO BS.ByteString, IO Int)
fakeResource chunks = do
    remaining <- IORef.newIORef (map BS.pack chunks)
    closes <- IORef.newIORef (0 :: Int)
    let acquire = return (Just ())
        release () = do
            count <- IORef.readIORef closes
            IORef.writeIORef closes (count + 1)
        readChunk () = do
            queued <- IORef.readIORef remaining
            case queued of
                [] -> return BS.empty
                chunk : rest -> do
                    IORef.writeIORef remaining rest
                    return chunk
    return (acquire, release, readChunk, IORef.readIORef closes)

-- Test harness.

-- | Hands one stream value to an iteratee, mirroring the bind-time feed.
step :: Iteratee.Stream e -> Iteratee.Iter e a -> Iteratee.Iter e a
step s it = case it of
    Iteratee.NeedInput k -> k s
    Iteratee.Done a _ -> Iteratee.Done a s
    Iteratee.IterFailed err _ -> Iteratee.IterFailed err s
    Iteratee.IterM _ -> it

{- | Drives an iteratee with a scripted chunk list and reports the result with
the number of times the producer was asked for input.
-}
drive :: [String] -> Iteratee.Iter TestError a -> IO (Either TestError a, Int)
drive chunks iter = do
    remaining <- IORef.newIORef (map BS.pack chunks)
    pulls <- IORef.newIORef (0 :: Int)
    let enum it = case it of
            Iteratee.Done _ _ -> return it
            Iteratee.IterFailed _ _ -> return it
            Iteratee.IterM m -> m >>= enum
            Iteratee.NeedInput k -> do
                count <- IORef.readIORef pulls
                IORef.writeIORef pulls (count + 1)
                queued <- IORef.readIORef remaining
                case queued of
                    [] -> enum (k (Iteratee.EndOfStream Nothing))
                    chunk : rest -> do
                        IORef.writeIORef remaining rest
                        enum (k (Iteratee.Chunk chunk))
    final <- enum iter
    result <- Iteratee.run final
    pullCount <- IORef.readIORef pulls
    return (result, pullCount)

extract :: Iteratee.Iter e a -> Either e a
extract it = case it of
    Iteratee.Done a _ -> Right a
    Iteratee.IterFailed err _ -> Left err
    Iteratee.NeedInput _ -> error "extract: still needs input"
    Iteratee.IterM _ -> error "extract: unresolved effect"

{- | A fold that collects the chunks it is given, newest first, and fails once it
has seen more than @limit@ bytes. Enough of a step to show what 'foldChunksI'
hands it and what it does with a refusal.
-}
collectFold :: Int -> Iteratee.Iter TestError [BS.ByteString]
collectFold limit = fmap snd (Iteratee.foldChunksI stepChunk (0 :: Int, []))
  where
    stepChunk (seen, acc) bytes
        | seen + BS.length bytes > limit = pure (Left TooLarge)
        | otherwise = pure (Right (seen + BS.length bytes, bytes : acc))

residueOf :: Iteratee.Iter e a -> Maybe (Iteratee.Stream e)
residueOf it = case it of
    Iteratee.Done _ s -> Just s
    Iteratee.IterFailed _ s -> Just s
    _ -> Nothing

isDone :: Iteratee.Iter e a -> Bool
isDone it = case it of
    Iteratee.Done _ _ -> True
    _ -> False

isFailed :: Iteratee.Iter e a -> Bool
isFailed it = case it of
    Iteratee.IterFailed _ _ -> True
    _ -> False

isNeedInput :: Iteratee.Iter e a -> Bool
isNeedInput it = case it of
    Iteratee.NeedInput _ -> True
    _ -> False

isLeft :: Either e a -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
