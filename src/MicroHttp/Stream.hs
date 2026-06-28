{- | The server's stream error vocabulary and the effectful producers and
sinks that bridge sockets and files to the general 'MicroHttp.Iteratee'
core. The core is error-generic; this layer fixes the error type to
'StreamError' and owns the resource lifetimes (a producer opens, feeds, and
closes its resource itself).
-}
module MicroHttp.Stream (
    StreamError (..),
    strictEnumerator,
    socketEnumerator,
    socketSinkI,
    fileEnumerator,
) where

import qualified Data.ByteString as BS
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Network.Socket as Socket
import qualified System.IO.Base as Base
import qualified System.IO.Open as Open

{- | A failure anywhere in the server's stream pipeline. Read and write
transport failures are distinct so the server can tell which side failed; a
parse or limit failure and a producer-resource failure (such as a file that
will not open) are separate again.
-}
data StreamError
    = StreamReadError Socket.SocketError
    | StreamWriteError Socket.SocketError
    | StreamParseError Parse.ParseError
    | StreamSourceError String
    | StreamTimeout
    deriving (Eq, Show)

-- | Re-export of the strict in-memory enumerator from the iteratee core.
strictEnumerator :: BS.ByteString -> Iteratee.Enumerator e a
strictEnumerator = Iteratee.strictEnumerator

{- | Feeds @recv@ chunks from a socket until orderly close or transport
failure, with each read's idle wait bounded by @idleMicros@ (non-positive
disables the bound). An empty read is orderly end of stream; a read error
ends the stream carrying the failure, and an idle-read timeout ends it with
'StreamTimeout'. Stops as soon as the consumer resolves.
-}
socketEnumerator :: Socket.ClientSocket -> Int -> Int -> Iteratee.Enumerator StreamError a
socketEnumerator socket bufferSize idleMicros = loop
  where
    loop it = case it of
        Iteratee.NeedInput k -> do
            received <- Socket.recvWithin idleMicros socket bufferSize
            case received of
                Left err -> return (k (Iteratee.EndOfStream (Just (toStreamError err))))
                Right bytes
                    | BS.null bytes -> return (k (Iteratee.EndOfStream Nothing))
                    | otherwise -> loop (k (Iteratee.Chunk bytes))
        Iteratee.IterM m -> m >>= loop
        _ -> return it
    toStreamError err
        | Socket.isTimeoutError err = StreamTimeout
        | otherwise = StreamReadError err

{- | Sends each chunk with @sendAll@ until end of stream. A send failure is a
terminal write failure; an upstream failure delivered at end of stream is
propagated unchanged.
-}
socketSinkI :: Socket.ClientSocket -> Iteratee.Iter StreamError ()
socketSinkI socket = Iteratee.byteSinkI (socketWrite socket)

-- | Sends bytes over a socket, tagging a failure as a write failure.
socketWrite :: Socket.ClientSocket -> BS.ByteString -> IO (Either StreamError ())
socketWrite socket bytes = do
    sent <- Socket.sendAll socket bytes
    case sent of
        Left err -> return (Left (StreamWriteError err))
        Right () -> return (Right ())

{- | Streams a file in chunks, owning the handle: it opens the file, feeds
its contents, and closes the handle on every exit path, including a consumer
that completes early or fails mid-stream. A file that will not open ends the
stream with a 'StreamSourceError'.
-}
fileEnumerator :: FilePath -> Iteratee.Enumerator StreamError a
fileEnumerator path =
    Iteratee.resourceEnumerator
        (Open.openBinaryFileM path Base.ReadMode)
        Base.hClose
        (`BS.hGet` fileChunkBytes)
        (StreamSourceError ("cannot open file: " ++ path))

-- | The chunk size, in bytes, used when streaming a file.
fileChunkBytes :: Int
fileChunkBytes = 4096
