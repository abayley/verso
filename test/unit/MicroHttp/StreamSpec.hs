module MicroHttp.StreamSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef
import MicroHttp.Http.Parser (ParseError (..))
import MicroHttp.Network.Socket (SocketError)
import MicroHttp.Stream
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Stream" $ do
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
            (result, _) <- drive ["hello", " world"] (readBodyStrict 100)
            result `shouldBe` Right (BS.pack "hello world")
        it "given a bound below the body size, when reading strictly, then the iteratee fails as body too large" $ do
            (result, _) <- drive ["hello", " world"] (readBodyStrict 3)
            result `shouldBe` Left (IterParseError BodyTooLarge)
        it "given a takeN bound, when the inner iteratee consumes, then it sees exactly n bytes and outer residue is preserved" $ do
            (result, _) <- drive ["AAAAABBB"] (pair (takeN 5 collectAll) collectAll)
            result `shouldBe` Right (BS.pack "AAAAA", BS.pack "BBB")
        it "given a takeN bound, when the inner iteratee completes early, then the unread remainder stays in the outer residue" $ do
            (result, _) <- drive ["AAABBBBBB"] (pair (takeN 10 (takeExactly 3)) collectAll)
            result `shouldBe` Right (BS.pack "AAA", BS.pack "BBBBBB")

-- Test-local consumers, built from the exported Iter constructors.

{- | Reads exactly @total@ bytes, keeping any surplus as residue; fails if the
stream ends first.
-}
takeExactly :: Int -> Iter BS.ByteString
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
collectAll :: Iter BS.ByteString
collectAll = go []
  where
    go acc = NeedInput (consume acc)
    consume acc s = case s of
        Chunk bytes
            | BS.null bytes -> go acc
            | otherwise -> go (bytes : acc)
        EndOfStream _ -> Done (BS.concat (reverse acc)) (EndOfStream Nothing)

-- | Fails on the first input, keeping it as residue.
failOnInput :: Iter ()
failOnInput = NeedInput consume
  where
    consume s = case s of
        Chunk bytes -> IterFailed (IterParseError (BadRequest "boom")) (Chunk bytes)
        EndOfStream merr -> IterFailed (incompleteError merr) (EndOfStream merr)

incompleteError :: Maybe SocketError -> IterError
incompleteError (Just err) = IterReadError err
incompleteError Nothing = IterParseError (BadRequest "incomplete")

pair :: Iter a -> Iter b -> Iter (a, b)
pair left right = do
    a <- left
    b <- right
    pure (a, b)

-- Test harness.

-- | Hands one stream value to an iteratee, mirroring the bind-time feed.
step :: Stream -> Iter a -> Iter a
step s it = case it of
    NeedInput k -> k s
    Done a _ -> Done a s
    IterFailed err _ -> IterFailed err s
    IterM _ -> it

{- | Drives an iteratee with a scripted chunk list and reports the result with
the number of times the producer was asked for input.
-}
drive :: [String] -> Iter a -> IO (Either IterError a, Int)
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

extract :: Iter a -> Either IterError a
extract it = case it of
    Done a _ -> Right a
    IterFailed err _ -> Left err
    NeedInput _ -> Left (IterParseError (BadRequest "still needs input"))
    IterM _ -> Left (IterParseError (BadRequest "unresolved effect"))

residueOf :: Iter a -> Maybe Stream
residueOf it = case it of
    Done _ s -> Just s
    IterFailed _ s -> Just s
    _ -> Nothing

isDone :: Iter a -> Bool
isDone it = case it of
    Done _ _ -> True
    _ -> False

isFailed :: Iter a -> Bool
isFailed it = case it of
    IterFailed _ _ -> True
    _ -> False

isNeedInput :: Iter a -> Bool
isNeedInput it = case it of
    NeedInput _ -> True
    _ -> False
