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
import MicroHttp.Http.Parse (ParseError)
import MicroHttp.Iteratee (Enumerator, Iter (..), Stream (..), byteSinkI, resourceEnumerator, strictEnumerator)
import MicroHttp.Network.Socket (ClientSocket, SocketError, recv, sendAll)
import System.IO.Base (IOMode (..), hClose)
import System.IO.Open (openBinaryFileM)

{- | A failure anywhere in the server's stream pipeline. Read and write
transport failures are distinct so the server can tell which side failed; a
parse or limit failure and a producer-resource failure (such as a file that
will not open) are separate again.
-}
data StreamError
    = StreamReadError SocketError
    | StreamWriteError SocketError
    | StreamParseError ParseError
    | StreamSourceError String
    deriving (Eq, Show)

{- | Feeds @recv@ chunks from a socket until orderly close or transport
failure. An empty read is orderly end of stream; a read error ends the
stream carrying the failure. Stops as soon as the consumer resolves.
-}
socketEnumerator :: ClientSocket -> Int -> Enumerator StreamError a
socketEnumerator socket bufferSize = loop
  where
    loop it = case it of
        NeedInput k -> do
            received <- recv socket bufferSize
            case received of
                Left err -> return (k (EndOfStream (Just (StreamReadError err))))
                Right bytes
                    | BS.null bytes -> return (k (EndOfStream Nothing))
                    | otherwise -> loop (k (Chunk bytes))
        IterM m -> m >>= loop
        _ -> return it

{- | Sends each chunk with @sendAll@ until end of stream. A send failure is a
terminal write failure; an upstream failure delivered at end of stream is
propagated unchanged.
-}
socketSinkI :: ClientSocket -> Iter StreamError ()
socketSinkI socket = byteSinkI (socketWrite socket)

-- | Sends bytes over a socket, tagging a failure as a write failure.
socketWrite :: ClientSocket -> BS.ByteString -> IO (Either StreamError ())
socketWrite socket bytes = do
    sent <- sendAll socket bytes
    case sent of
        Left err -> return (Left (StreamWriteError err))
        Right () -> return (Right ())

{- | Streams a file in chunks, owning the handle: it opens the file, feeds
its contents, and closes the handle on every exit path, including a consumer
that completes early or fails mid-stream. A file that will not open ends the
stream with a 'StreamSourceError'.
-}
fileEnumerator :: FilePath -> Enumerator StreamError a
fileEnumerator path =
    resourceEnumerator
        (openBinaryFileM path ReadMode)
        hClose
        (`BS.hGet` fileChunkBytes)
        (StreamSourceError ("cannot open file: " ++ path))

fileChunkBytes :: Int
fileChunkBytes = 4096
