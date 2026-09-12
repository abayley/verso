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
    fileEnumeratorChunked,
    foldFileBlocks,
    fileContains,
    transformedFileBody,
    transformedTempFileBody,
    copyFile,
    fileSinkI,
    filesEqual,
) where

import qualified Control.Monad as Monad
import qualified Data.ByteString as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Bytes as Bytes
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Http.Parse as Parse
import MicroHttp.Iteratee (strictEnumerator)
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

-- strictEnumerator is re-exported from the iteratee core directly (not via a
-- local alias): a wrapper binding is a distinct name, and re-exporting both
-- from the MicroHttp facade is then a conflicting-export error under GHC.

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
stream with a 'StreamSourceError'. Chunks are 'fileChunkBytes', sized for
socket traffic; 'fileEnumeratorChunked' takes the size for consumers that
scan documents.
-}
fileEnumerator :: FilePath -> Iteratee.Enumerator StreamError a
fileEnumerator = fileEnumeratorChunked fileChunkBytes

-- | 'fileEnumerator' with the chunk size in bytes chosen by the caller.
fileEnumeratorChunked :: Int -> FilePath -> Iteratee.Enumerator StreamError a
fileEnumeratorChunked chunkBytes path =
    Iteratee.resourceEnumerator
        (Open.openBinaryFileM path Base.ReadMode)
        Base.hClose
        (`BS.hGet` chunkBytes)
        (StreamSourceError ("cannot open file: " ++ path))

-- | The default chunk size, in bytes, used when streaming a file.
fileChunkBytes :: Int
fileChunkBytes = 4096

{- | Folds a per-block step over a file read in @blockSize@ blocks, holding only
one block at a time. Used to compute a document's escaped length before it is
streamed, so the sized response has an exact @Content-Length@ (RFC-0040) without
holding the whole file. A file that will not open is a 'StreamSourceError'; the
handle is closed on the ordinary path.
-}
foldFileBlocks :: Int -> (a -> BS.ByteString -> IO a) -> a -> FilePath -> IO (Either StreamError a)
foldFileBlocks blockSize step initial path = do
    opened <- Open.openBinaryFileM path Base.ReadMode
    case opened of
        Nothing -> pure (Left (StreamSourceError ("cannot open file: " ++ path)))
        Just handle -> do
            result <- loop handle initial
            Base.hClose handle
            pure (Right result)
  where
    loop handle acc = do
        block <- BS.hGet handle blockSize
        if BS.null block
            then pure acc
            else do
                acc' <- step acc block
                loop handle acc'

{- | Whether @needle@ occurs anywhere in the file at @path@, read in blocks so the
file is never held whole (RFC-0040). Each block is scanned with 'Bytes.isInfixOf'
after prepending the last @length needle - 1@ bytes of the previous block, so a
match straddling a block boundary is still found; memory is one block plus that
overlap, whatever the file's size. Used to keep a tree walk's per-page pre-filter
constant-space. A file that will not open is a 'StreamSourceError'.
-}
fileContains :: BS.ByteString -> FilePath -> IO (Either StreamError Bool)
fileContains needle path
    | BS.null needle = do
        -- An empty needle is contained in any readable file (BS.isInfixOf semantics).
        opened <- Open.openBinaryFileM path Base.ReadMode
        case opened of
            Nothing -> pure (Left (StreamSourceError ("cannot open file: " ++ path)))
            Just handle -> Base.hClose handle >> pure (Right True)
    | otherwise = fmap (fmap fst) (foldFileBlocks containsBlockBytes step (False, BS.empty) path)
  where
    overlap = BS.length needle - 1
    step (found, carry) block
        | found = pure (True, BS.empty)
        | otherwise =
            let hay = if BS.null carry then block else BS.append carry block
                carry' = if BS.length hay <= overlap then hay else BS.drop (BS.length hay - overlap) hay
             in pure (Bytes.isInfixOf needle hay, carry')

-- | The block size for 'fileContains'.
containsBlockBytes :: Int
containsBlockBytes = 65536

-- | The producer's phase: the prefix, the file's blocks, the suffix, then done.
data BodyPhase = SendBefore | SendBlocks | SendAfter | SendDone

{- | A body producer that emits @before@, then each @blockSize@ block of @path@
passed through @transform@, then @after@ (RFC-0040). The file is the one resource:
opened on demand, closed on every exit path, including a consumer that completes
early or fails mid-stream. It carries no whole-file value, so the response is
bounded by @before@, one block, and @after@ whatever the file's size. With
@transform@ the byte-wise HTML escaper and @before@/@after@ the shell either side
of the document hole, this is the streamed document page; the exact
@Content-Length@ comes from 'foldFileBlocks' over the same @transform@'s length.
An empty @before@ or @after@ contributes nothing.
-}
transformedFileBody ::
    Int ->
    BS.ByteString ->
    (BS.ByteString -> IO BS.ByteString) ->
    FilePath ->
    BS.ByteString ->
    Iteratee.Enumerator StreamError a
transformedFileBody = transformedFileBodyImpl False

{- | As 'transformedFileBody', but removes @path@ once the body is fully produced
(or the consumer stops or fails mid-stream): for a temporary capture served once,
such as a document at a git revision (RFC-0040). The removal runs on the same
resource-release path as the handle close, so a client that disconnects part-way
still cleans up.
-}
transformedTempFileBody ::
    Int ->
    BS.ByteString ->
    (BS.ByteString -> IO BS.ByteString) ->
    FilePath ->
    BS.ByteString ->
    Iteratee.Enumerator StreamError a
transformedTempFileBody = transformedFileBodyImpl True

transformedFileBodyImpl ::
    Bool ->
    Int ->
    BS.ByteString ->
    (BS.ByteString -> IO BS.ByteString) ->
    FilePath ->
    BS.ByteString ->
    Iteratee.Enumerator StreamError a
transformedFileBodyImpl removeAfter blockSize before transform path after =
    Iteratee.resourceEnumerator acquire release readChunk acquireError
  where
    acquireError = StreamSourceError ("cannot open file: " ++ path)
    acquire = do
        opened <- Open.openBinaryFileM path Base.ReadMode
        case opened of
            Nothing -> pure Nothing
            Just handle -> do
                phase <- IORef.newIORef SendBefore
                pure (Just (phase, handle))
    release (_, handle) = do
        Base.hClose handle
        Monad.when removeAfter (Monad.void (FileSystem.removeFilePath path))
    readChunk resource@(phase, handle) = do
        current <- IORef.readIORef phase
        case current of
            SendBefore -> do
                IORef.writeIORef phase SendBlocks
                if BS.null before then readChunk resource else pure before
            SendBlocks -> do
                block <- BS.hGet handle blockSize
                if BS.null block
                    then IORef.writeIORef phase SendAfter >> readChunk resource
                    else transform block
            SendAfter -> do
                IORef.writeIORef phase SendDone
                pure after
            SendDone -> pure BS.empty

{- | Copies a file in 'fileChunkBytes' chunks, so a large file is never held whole. A
destination that will not open, or a source that will not, is a 'StreamSourceError';
the destination is left as whatever was written when the source fails part-way.
-}
copyFile :: FilePath -> FilePath -> IO (Either StreamError ())
copyFile from to = do
    opened <- Open.openBinaryFileM to Base.WriteMode
    case opened of
        Nothing -> pure (Left (StreamSourceError ("cannot open file: " ++ to)))
        Just handle -> do
            outcome <- fileEnumerator from (Iteratee.byteSinkI (\bytes -> BS.hPut handle bytes >> pure (Right ()))) >>= Iteratee.run
            Base.hClose handle
            pure outcome

{- | Sinks a stream to a file, chunk by chunk, and yields the byte count. The
body never exists as a value: this is what a handler uses when the bytes'
destination is a file, in place of 'Iteratee.readBodyStrict' (RFC-0040).

The cap is checked before each write, so an over-cap stream fails with the
supplied error having written at most @limit@ bytes, and the partial file is
removed. A transport failure at end of stream, or a file that will not open,
also removes the partial file; the caller sees only a complete file or none.
The file is opened on first demand and closed on every exit path.
-}
fileSinkI :: Int -> StreamError -> FilePath -> Iteratee.Iter StreamError Int
fileSinkI limit tooLarge path = Iteratee.IterM $ do
    opened <- Open.openBinaryFileM path Base.WriteMode
    pure $ case opened of
        Nothing -> Iteratee.IterFailed (StreamSourceError ("cannot open file: " ++ path)) (Iteratee.Chunk BS.empty)
        Just handle -> loop handle 0
  where
    loop handle count = Iteratee.NeedInput (consume handle count)
    consume handle count s = case s of
        Iteratee.Chunk bytes
            | BS.null bytes -> loop handle count
            | count + BS.length bytes > limit -> abandon handle (Iteratee.IterFailed tooLarge (Iteratee.Chunk bytes))
            | otherwise -> Iteratee.IterM (BS.hPut handle bytes >> pure (loop handle (count + BS.length bytes)))
        Iteratee.EndOfStream Nothing -> Iteratee.IterM (Base.hClose handle >> pure (Iteratee.Done count (Iteratee.EndOfStream Nothing)))
        Iteratee.EndOfStream (Just err) -> abandon handle (Iteratee.IterFailed err (Iteratee.EndOfStream (Just err)))
    -- close and remove the partial file, then resolve to the given failure
    abandon handle failure = Iteratee.IterM $ do
        Base.hClose handle
        _ <- FileSystem.removeFilePath path
        pure failure

{- | Whether two files hold identical bytes, without reading either whole: a size
check by @stat@ answers most mismatches for free, and equal sizes are then
compared a 64KB block at a time. Replaces reading both files into memory to
compare them (asset de-duplication and move conflict checks, RFC-0040). A file
that cannot be stat-ed or opened is a failure, not a verdict.
-}
filesEqual :: FilePath -> FilePath -> IO (Either StreamError Bool)
filesEqual pathA pathB = do
    statA <- FileSystem.fileStat pathA
    statB <- FileSystem.fileStat pathB
    case (statA, statB) of
        (Left e, _) -> pure (Left (StreamSourceError ("cannot stat " ++ pathA ++ ": " ++ show e)))
        (_, Left e) -> pure (Left (StreamSourceError ("cannot stat " ++ pathB ++ ": " ++ show e)))
        (Right a, Right b)
            | FileSystem.fsSize a /= FileSystem.fsSize b -> pure (Right False)
            | otherwise -> compareContents
  where
    compareContents = do
        openedA <- Open.openBinaryFileM pathA Base.ReadMode
        case openedA of
            Nothing -> pure (Left (StreamSourceError ("cannot open file: " ++ pathA)))
            Just handleA -> do
                openedB <- Open.openBinaryFileM pathB Base.ReadMode
                case openedB of
                    Nothing -> Base.hClose handleA >> pure (Left (StreamSourceError ("cannot open file: " ++ pathB)))
                    Just handleB -> do
                        verdict <- loop handleA handleB
                        Base.hClose handleA
                        Base.hClose handleB
                        pure (Right verdict)
    loop handleA handleB = do
        blockA <- BS.hGet handleA compareBlockBytes
        blockB <- BS.hGet handleB compareBlockBytes
        if blockA /= blockB
            then pure False
            else if BS.null blockA then pure True else loop handleA handleB

-- | The block size for the streamed comparison.
compareBlockBytes :: Int
compareBlockBytes = 65536
