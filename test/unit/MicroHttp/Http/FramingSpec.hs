module MicroHttp.Http.FramingSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Stream as Stream
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Framing" $ do
        it "given headers split across chunks, when framing headers, then the head is assembled and the residue is the body prefix" $ do
            final <- driveHeaders ["POST /d HTTP/1.1\r\nContent-Length: 5", "\r\n\r\nhello"] Http.defaultParseLimits
            headOf final `shouldBe` Just (BS.pack "POST /d HTTP/1.1\r\nContent-Length: 5")
            residueOf final `shouldBe` Just (Iteratee.Chunk (BS.pack "hello"))
        it "given headers that never terminate within the limit, when framing headers, then header too large is returned" $ do
            final <- driveHeaders ["GET / HTTP/1.1\r\nX: yyyyyyyyyyyy", "zzzzzzzzzzzzzzzz"] Http.ParseLimits{Http.maxHeaderBytes = 16, Http.maxBodyBytes = 100}
            errorOf final `shouldBe` Just (Stream.StreamParseError Http.HeaderTooLarge)

driveHeaders :: [String] -> Http.ParseLimits -> IO (Iteratee.Iter Stream.StreamError BS.ByteString)
driveHeaders chunks limits = do
    remaining <- IORef.newIORef (map BS.pack chunks)
    let enum it = case it of
            Iteratee.Done _ _ -> return it
            Iteratee.IterFailed _ _ -> return it
            Iteratee.IterM m -> m >>= enum
            Iteratee.NeedInput k -> do
                queued <- IORef.readIORef remaining
                case queued of
                    [] -> enum (k (Iteratee.EndOfStream Nothing))
                    chunk : rest -> do
                        IORef.writeIORef remaining rest
                        enum (k (Iteratee.Chunk chunk))
    enum (Http.frameHeadersI limits)

headOf :: Iteratee.Iter Stream.StreamError BS.ByteString -> Maybe BS.ByteString
headOf it = case it of
    Iteratee.Done value _ -> Just value
    _ -> Nothing

residueOf :: Iteratee.Iter Stream.StreamError a -> Maybe (Iteratee.Stream Stream.StreamError)
residueOf it = case it of
    Iteratee.Done _ s -> Just s
    Iteratee.IterFailed _ s -> Just s
    _ -> Nothing

errorOf :: Iteratee.Iter Stream.StreamError a -> Maybe Stream.StreamError
errorOf it = case it of
    Iteratee.IterFailed err _ -> Just err
    _ -> Nothing
