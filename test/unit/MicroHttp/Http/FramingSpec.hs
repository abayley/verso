module MicroHttp.Http.FramingSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef
import MicroHttp.Http.Framing
import MicroHttp.Http.Parser (ParseError (..), ParseLimits (..), defaultParseLimits)
import MicroHttp.Iteratee (Iter (..), Stream (..))
import MicroHttp.Stream (StreamError (..))
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Framing" $ do
        it "given headers split across chunks, when framing, then the complete request is assembled" $ do
            source <- scriptedSource ["GET /docs HT", "TP/1.1\r\nHost: example", "\r\n\r\n"]
            framed <- frameRequest source defaultParseLimits
            framed `shouldBe` Right (BS.pack "GET /docs HTTP/1.1\r\nHost: example\r\n\r\n")
        it "given a body split across chunks, when framing, then the declared body is assembled" $ do
            source <-
                scriptedSource
                    ["POST /d HTTP/1.1\r\nContent-Length: 12\r\n\r\nhello", " world!"]
            framed <- frameRequest source defaultParseLimits
            framed `shouldBe` Right (BS.pack "POST /d HTTP/1.1\r\nContent-Length: 12\r\n\r\nhello world!")
        it "given headers that never terminate within the limit, when framing, then header too large is returned" $ do
            source <- scriptedSource ["GET / HTTP/1.1\r\nX: yyyyyyyyyyyy", "zzzzzzzzzzzzzzzz"]
            framed <- frameRequest source ParseLimits{maxHeaderBytes = 16, maxBodyBytes = 100}
            framed `shouldBe` (Left (FrameParseError HeaderTooLarge) :: Either (FrameError String) BS.ByteString)
        it "given a declared body above the limit, when framing, then body too large is returned before the body" $ do
            source <- scriptedSource ["POST /d HTTP/1.1\r\nContent-Length: 1000\r\n\r\n"]
            framed <- frameRequest source ParseLimits{maxHeaderBytes = 8192, maxBodyBytes = 100}
            framed `shouldBe` (Left (FrameParseError BodyTooLarge) :: Either (FrameError String) BS.ByteString)
        it "given no content length, when framing, then the request completes at the end of the headers" $ do
            source <- scriptedSource ["GET / HTTP/1.1\r\nHost: h\r\n\r\nEXTRA"]
            framed <- frameRequest source defaultParseLimits
            framed `shouldBe` Right (BS.pack "GET / HTTP/1.1\r\nHost: h\r\n\r\n")
        it "given the peer closes before the declared body arrives, when framing, then an incomplete body error is returned" $ do
            source <- scriptedSource ["POST /d HTTP/1.1\r\nContent-Length: 10\r\n\r\nfour"]
            framed <- frameRequest source defaultParseLimits
            framed
                `shouldBe` (Left (FrameParseError (BadRequest "incomplete body")) :: Either (FrameError String) BS.ByteString)
        it "given headers split across chunks, when framing headers, then the head is assembled and the residue is the body prefix" $ do
            final <- driveHeaders ["POST /d HTTP/1.1\r\nContent-Length: 5", "\r\n\r\nhello"] defaultParseLimits
            headOf final `shouldBe` Just (BS.pack "POST /d HTTP/1.1\r\nContent-Length: 5")
            residueOf final `shouldBe` Just (Chunk (BS.pack "hello"))
        it "given headers that never terminate within the limit, when framing headers, then header too large is returned" $ do
            final <- driveHeaders ["GET / HTTP/1.1\r\nX: yyyyyyyyyyyy", "zzzzzzzzzzzzzzzz"] ParseLimits{maxHeaderBytes = 16, maxBodyBytes = 100}
            errorOf final `shouldBe` Just (StreamParseError HeaderTooLarge)

scriptedSource :: [String] -> IO (IO (Either String BS.ByteString))
scriptedSource chunks = do
    remaining <- newIORef (map BS.pack chunks)
    return $ do
        queued <- readIORef remaining
        case queued of
            [] -> return (Right BS.empty)
            chunk : rest -> do
                writeIORef remaining rest
                return (Right chunk)

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
