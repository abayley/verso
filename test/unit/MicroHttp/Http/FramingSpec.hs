module MicroHttp.Http.FramingSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef
import MicroHttp.Http (ParseError (..), ParseLimits (..), defaultParseLimits, frameHeadersI)
import MicroHttp.Iteratee (Iter (..), Stream (..))
import MicroHttp.Stream (StreamError (..))
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Framing" $ do
        it "given headers split across chunks, when framing headers, then the head is assembled and the residue is the body prefix" $ do
            final <- driveHeaders ["POST /d HTTP/1.1\r\nContent-Length: 5", "\r\n\r\nhello"] defaultParseLimits
            headOf final `shouldBe` Just (BS.pack "POST /d HTTP/1.1\r\nContent-Length: 5")
            residueOf final `shouldBe` Just (Chunk (BS.pack "hello"))
        it "given headers that never terminate within the limit, when framing headers, then header too large is returned" $ do
            final <- driveHeaders ["GET / HTTP/1.1\r\nX: yyyyyyyyyyyy", "zzzzzzzzzzzzzzzz"] ParseLimits{maxHeaderBytes = 16, maxBodyBytes = 100}
            errorOf final `shouldBe` Just (StreamParseError HeaderTooLarge)

driveHeaders :: [String] -> ParseLimits -> IO (Iter StreamError BS.ByteString)
driveHeaders chunks limits = do
    remaining <- newIORef (map BS.pack chunks)
    let enum it = case it of
            Done _ _ -> return it
            IterFailed _ _ -> return it
            IterM m -> m >>= enum
            NeedInput k -> do
                queued <- readIORef remaining
                case queued of
                    [] -> enum (k (EndOfStream Nothing))
                    chunk : rest -> do
                        writeIORef remaining rest
                        enum (k (Chunk chunk))
    enum (frameHeadersI limits)

headOf :: Iter StreamError BS.ByteString -> Maybe BS.ByteString
headOf it = case it of
    Done value _ -> Just value
    _ -> Nothing

residueOf :: Iter StreamError a -> Maybe (Stream StreamError)
residueOf it = case it of
    Done _ s -> Just s
    IterFailed _ s -> Just s
    _ -> Nothing

errorOf :: Iter StreamError a -> Maybe StreamError
errorOf it = case it of
    IterFailed err _ -> Just err
    _ -> Nothing
