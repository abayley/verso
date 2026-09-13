module MicroHttp.IterateeSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Iteratee as Iteratee
import Test.Hspec

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
