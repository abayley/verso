module MicroHttp.IterateeSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef
import MicroHttp.Iteratee
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
            let once = step (EndOfStream Nothing) collectAll
                twice = step (EndOfStream Nothing) once
            isDone once `shouldBe` True
            extract once `shouldBe` extract twice
            extract twice `shouldBe` Right (BS.pack "")
        it "given end of stream, when a consumer needs more input, then it resolves to a failure rather than NeedInput" $ do
            let result = step (EndOfStream Nothing) (takeExactly 5)
            isFailed result `shouldBe` True
            isNeedInput result `shouldBe` False
        it "given a failing iteratee, when it fails mid-chunk, then IterFailed carries the unconsumed residue" $ do
            let result = step (Chunk (BS.pack "LEFTOVER")) failOnInput
            residueOf result `shouldBe` Just (Chunk (BS.pack "LEFTOVER"))
        it "given a body within the bound, when reading strictly, then the whole body is returned" $ do
            (result, _) <- drive ["hello", " world"] (readBodyStrict TooLarge 100)
            result `shouldBe` Right (BS.pack "hello world")
        it "given a bound below the body size, when reading strictly, then the iteratee fails with the supplied error" $ do
            (result, _) <- drive ["hello", " world"] (readBodyStrict TooLarge 3)
            result `shouldBe` Left TooLarge
        it "given a takeN bound, when the inner iteratee consumes, then it sees exactly n bytes and outer residue is preserved" $ do
            (result, _) <- drive ["AAAAABBB"] (pair (takeN 5 collectAll) collectAll)
            result `shouldBe` Right (BS.pack "AAAAA", BS.pack "BBB")
        it "given a takeN bound, when the inner iteratee completes early, then the unread remainder stays in the outer residue" $ do
            (result, _) <- drive ["AAABBBBBB"] (pair (takeN 10 (takeExactly 3)) collectAll)
            result `shouldBe` Right (BS.pack "AAA", BS.pack "BBBBBB")
        it "given a strict enumerator, when run into a collecting consumer, then the value round-trips" $ do
            final <- strictEnumerator (BS.pack "payload bytes") (readBodyStrict TooLarge 1000)
            result <- run final
            result `shouldBe` Right (BS.pack "payload bytes")
        it "given a bracketed resource enumerator, when the consumer completes, then the resource is released exactly once" $ do
            (acquire, release, readChunk, closeCount) <- fakeResource ["AB", "CD"]
            final <- resourceEnumerator acquire release readChunk Boom (readBodyStrict TooLarge 1000)
            result <- run final
            result `shouldBe` Right (BS.pack "ABCD")
            closeCount `shouldReturn` 1
        it "given a bracketed resource enumerator, when the consumer fails mid-stream, then the resource is still released" $ do
            (acquire, release, readChunk, closeCount) <- fakeResource ["AB", "CD"]
            final <- resourceEnumerator acquire release readChunk Boom failOnInput
            result <- run final
            isLeft result `shouldBe` True
            closeCount `shouldReturn` 1
        it "given a bracketed resource enumerator, when the consumer stops early, then the resource is released" $ do
            (acquire, release, readChunk, closeCount) <- fakeResource ["AAAA", "BBBB"]
            final <- resourceEnumerator acquire release readChunk Boom (takeN 2 (readBodyStrict TooLarge 1000))
            result <- run final
            result `shouldBe` Right (BS.pack "AA")
            closeCount `shouldReturn` 1
        it "given a resource that fails to acquire, when enumerated, then the consumer sees the acquire error and nothing is released" $ do
            (_, release, readChunk, closeCount) <- fakeResource ["AB"]
            final <- resourceEnumerator (return Nothing) release readChunk Boom (readBodyStrict TooLarge 1000)
            result <- run final
            result `shouldBe` Left Boom
            closeCount `shouldReturn` 0

-- Test-local consumers, built from the exported Iter constructors.

{- | Reads exactly @total@ bytes, keeping any surplus as residue; fails if the
stream ends first.
-}
takeExactly :: Int -> Iter TestError BS.ByteString
takeExactly total = go total []
  where
    go remaining acc
        | remaining <= 0 = Done (BS.concat (reverse acc)) (Chunk BS.empty)
        | otherwise = NeedInput (consume remaining acc)
    consume remaining acc s = case s of
        Chunk bytes
            | BS.null bytes -> go remaining acc
            | BS.length bytes <= remaining -> go (remaining - BS.length bytes) (bytes : acc)
            | otherwise ->
                let (taken, rest) = BS.splitAt remaining bytes
                 in Done (BS.concat (reverse (taken : acc))) (Chunk rest)
        EndOfStream merr -> IterFailed (incompleteError merr) (EndOfStream merr)

-- | Reads to end of stream, returning the concatenation.
collectAll :: Iter TestError BS.ByteString
collectAll = go []
  where
    go acc = NeedInput (consume acc)
    consume acc s = case s of
        Chunk bytes
            | BS.null bytes -> go acc
            | otherwise -> go (bytes : acc)
        EndOfStream _ -> Done (BS.concat (reverse acc)) (EndOfStream Nothing)

-- | Fails on the first input, keeping it as residue.
failOnInput :: Iter TestError ()
failOnInput = NeedInput consume
  where
    consume s = case s of
        Chunk bytes -> IterFailed Boom (Chunk bytes)
        EndOfStream merr -> IterFailed (incompleteError merr) (EndOfStream merr)

incompleteError :: Maybe TestError -> TestError
incompleteError (Just err) = err
incompleteError Nothing = Incomplete

pair :: Iter e a -> Iter e b -> Iter e (a, b)
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
    remaining <- newIORef (map BS.pack chunks)
    closes <- newIORef (0 :: Int)
    let acquire = return (Just ())
        release () = do
            count <- readIORef closes
            writeIORef closes (count + 1)
        readChunk () = do
            queued <- readIORef remaining
            case queued of
                [] -> return BS.empty
                chunk : rest -> do
                    writeIORef remaining rest
                    return chunk
    return (acquire, release, readChunk, readIORef closes)

-- Test harness.

-- | Hands one stream value to an iteratee, mirroring the bind-time feed.
step :: Stream e -> Iter e a -> Iter e a
step s it = case it of
    NeedInput k -> k s
    Done a _ -> Done a s
    IterFailed err _ -> IterFailed err s
    IterM _ -> it

{- | Drives an iteratee with a scripted chunk list and reports the result with
the number of times the producer was asked for input.
-}
drive :: [String] -> Iter TestError a -> IO (Either TestError a, Int)
drive chunks iter = do
    remaining <- newIORef (map BS.pack chunks)
    pulls <- newIORef (0 :: Int)
    let enum it = case it of
            Done _ _ -> return it
            IterFailed _ _ -> return it
            IterM m -> m >>= enum
            NeedInput k -> do
                count <- readIORef pulls
                writeIORef pulls (count + 1)
                queued <- readIORef remaining
                case queued of
                    [] -> enum (k (EndOfStream Nothing))
                    chunk : rest -> do
                        writeIORef remaining rest
                        enum (k (Chunk chunk))
    final <- enum iter
    result <- run final
    pullCount <- readIORef pulls
    return (result, pullCount)

extract :: Iter e a -> Either e a
extract it = case it of
    Done a _ -> Right a
    IterFailed err _ -> Left err
    NeedInput _ -> error "extract: still needs input"
    IterM _ -> error "extract: unresolved effect"

residueOf :: Iter e a -> Maybe (Stream e)
residueOf it = case it of
    Done _ s -> Just s
    IterFailed _ s -> Just s
    _ -> Nothing

isDone :: Iter e a -> Bool
isDone it = case it of
    Done _ _ -> True
    _ -> False

isFailed :: Iter e a -> Bool
isFailed it = case it of
    IterFailed _ _ -> True
    _ -> False

isNeedInput :: Iter e a -> Bool
isNeedInput it = case it of
    NeedInput _ -> True
    _ -> False

isLeft :: Either e a -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
