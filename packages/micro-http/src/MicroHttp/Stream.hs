{- | The server's stream error vocabulary and the effectful producers and
sinks that bridge sockets and files to the general 'MicroHttp.Iteratee'
core. The core is error-generic; this layer fixes the error type to
'StreamError' and owns the resource lifetimes (a producer opens, feeds, and
closes its resource itself).
-}
module MicroHttp.Stream (
    StreamError (..),
    Iteratee.strictEnumerator,
    socketEnumerator,
    socketSinkI,
    fileEnumerator,
    fileEnumeratorChunked,
    tempFileEnumeratorChunked,
    foldFileBlocks,
    foldFileLines,
    foldFileTextLines,
    foldTempFileLines,
    foldTempFileTextLines,
    fileContains,
    transformedFileBody,
    transformedTempFileBody,
    copyFile,
    writeFileLines,
    fileSinkI,
    filesEqual,
    compareBlockBytes,
) where

import qualified Control.Exception as Exception
import qualified Control.Monad as Monad
import qualified Control.Monad.IO.Class as IOClass
import qualified Data.ByteString as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Bytes as Bytes
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Http.Parse as Parse
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Utf8 as Utf8
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
fileEnumerator :: (Iteratee.MonadRelease m) => FilePath -> Iteratee.EnumeratorT StreamError m a
fileEnumerator = fileEnumeratorChunked fileChunkBytes

{- | 'fileEnumerator' with the chunk size in bytes chosen by the caller. Generic
in the layer it feeds, so one file can be the inner stream of a two-source
consumer and another its outer stream ('filesEqual', RFC-0041).
-}
fileEnumeratorChunked :: (Iteratee.MonadRelease m) => Int -> FilePath -> Iteratee.EnumeratorT StreamError m a
fileEnumeratorChunked chunkBytes path =
    Iteratee.resourceEnumerator
        (Open.openBinaryFileM path Base.ReadMode)
        Base.hClose
        (`BS.hGet` chunkBytes)
        (StreamSourceError ("cannot open file: " ++ path))

{- | 'fileEnumeratorChunked' for a file this producer owns (RFC-0043): the file is
removed once the producer returns, however it returned -- the stream ended, the
consumer stopped early or failed, or an effect step threw. "Temp" in a name here
means exactly that: the producer deletes the file on release, so the file's owner
is whoever holds the producer.
-}
tempFileEnumeratorChunked :: (Iteratee.MonadRelease m) => Int -> FilePath -> Iteratee.EnumeratorT StreamError m a
tempFileEnumeratorChunked chunkBytes path = removingOnReturn path (fileEnumeratorChunked chunkBytes path)

-- | Wraps a producer so that @path@ is removed when it returns, exception included; a missing file is not an error.
removingOnReturn :: (Iteratee.MonadRelease m) => FilePath -> Iteratee.EnumeratorT e m a -> Iteratee.EnumeratorT e m a
removingOnReturn path producer it = do
    final <- Iteratee.releaseOnFailure remove (producer it)
    IOClass.liftIO remove
    pure final
  where
    remove = Monad.void (FileSystem.removeFilePath path)

-- | The default chunk size, in bytes, used when streaming a file.
fileChunkBytes :: Int
fileChunkBytes = 4096

{- | Folds a per-block step over a file read in @blockSize@ blocks, holding only
one block at a time (RFC-0040). Used to compute a document's escaped length before
it is streamed and to hash a page for change detection, without reading the file
into the heap. Built on 'fileEnumeratorChunked', the one file-reading bracket, so
the open/read/close discipline lives in a single place (ADR-0091). A file that
will not open is a 'StreamSourceError'.
-}
foldFileBlocks :: Int -> (a -> BS.ByteString -> IO a) -> a -> FilePath -> IO (Either StreamError a)
foldFileBlocks blockSize step initial path =
    fileEnumeratorChunked blockSize path (foldBlocksI step initial) >>= Iteratee.run

-- | A consumer that folds the effectful @step@ over every non-empty chunk it receives.
foldBlocksI :: (a -> BS.ByteString -> IO a) -> a -> Iteratee.Iter StreamError a
foldBlocksI step = Iteratee.foldChunksI (\acc block -> fmap Right (step acc block))

{- | Folds a per-line step over a file read in blocks, one line at a time, so a
line-oriented file (a git diff, a persisted index) is parsed without being held
whole or split with a whole-file @BS.lines@ (the MicroHs list-scan hazard). Lines
carry no trailing newline; a final line without a trailing newline is folded too.
Reproduces 'Prelude.lines' semantics (a blank line between two newlines is a line;
a trailing newline yields no extra empty line). A file that will not open is a
'StreamSourceError'. The file enumerator under 'Iteratee.linesI' (RFC-0043), so it
shares the one read bracket (ADR-0091).
-}
foldFileLines :: (a -> BS.ByteString -> IO a) -> a -> FilePath -> IO (Either StreamError a)
foldFileLines step initial path =
    fileEnumeratorChunked lineBlockBytes path (Iteratee.linesI (foldLinesI step initial)) >>= Iteratee.run

{- | 'foldFileLines' with each line decoded from UTF-8 to a 'String' (RFC-0043).
The decode happens after the line has been reassembled across block boundaries,
so a multi-byte character split by a block is decoded whole. This is the read for
a line-oriented text file whose values are names or paths: the step receives real
characters, never the byte-per-'Char' view of the bytes.
-}
foldFileTextLines :: (a -> String -> IO a) -> a -> FilePath -> IO (Either StreamError a)
foldFileTextLines step = foldFileLines (\acc line -> step acc (Utf8.decodeBytes line))

{- | 'foldFileLines' over a file the fold owns (RFC-0043): the file is removed when
the fold returns, whatever ended it. This is how a response body consumes a
process capture it was handed: the removal is the producer's release, not a line
after the fold.
-}
foldTempFileLines :: (a -> BS.ByteString -> IO a) -> a -> FilePath -> IO (Either StreamError a)
foldTempFileLines step initial path =
    tempFileEnumeratorChunked lineBlockBytes path (Iteratee.linesI (foldLinesI step initial)) >>= Iteratee.run

-- | 'foldFileTextLines' over a file the fold owns; see 'foldTempFileLines'.
foldTempFileTextLines :: (a -> String -> IO a) -> a -> FilePath -> IO (Either StreamError a)
foldTempFileTextLines step = foldTempFileLines (\acc line -> step acc (Utf8.decodeBytes line))

-- | Folds each delivered line, less its terminating newline, into the accumulator (the sink under 'Iteratee.linesI').
foldLinesI :: (a -> BS.ByteString -> IO a) -> a -> Iteratee.Iter StreamError a
foldLinesI step = Iteratee.foldChunksI (\acc line -> fmap Right (step acc (dropNewline line)))
  where
    dropNewline line = if BS.last line == 10 then BS.init line else line

-- | The block size for 'foldFileLines'.
lineBlockBytes :: Int
lineBlockBytes = 65536

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

{- | The shared producer behind 'transformedFileBody' and 'transformedTempFileBody':
three sources appended (RFC-0043): @before@, the file's blocks each passed through
@transform@ under one bracketed handle, then @after@. The flag says whether the
file is removed once the producer returns -- on completion, an early stop, or a
failure alike, including a stop during @before@ that never opened it. The file is
opened when its turn comes, so a missing file fails the stream after @before@ has
been produced.
-}
transformedFileBodyImpl ::
    Bool ->
    Int ->
    BS.ByteString ->
    (BS.ByteString -> IO BS.ByteString) ->
    FilePath ->
    BS.ByteString ->
    Iteratee.Enumerator StreamError a
transformedFileBodyImpl removeAfter blockSize before transform path after =
    -- the temp goes once the body has been produced or the consumer has stopped, even
    -- when it stopped during @before@ and the file was never opened, or a step threw
    (if removeAfter then removingOnReturn path else id) appended
  where
    appended =
        Iteratee.appendEnumerators
            [ Iteratee.strictEnumerator before
            , Iteratee.resourceEnumerator acquire Base.hClose readChunk acquireError
            , Iteratee.strictEnumerator after
            ]
    acquireError = StreamSourceError ("cannot open file: " ++ path)
    acquire = Open.openBinaryFileM path Base.ReadMode
    readChunk handle = do
        block <- BS.hGet handle blockSize
        if BS.null block then pure block else transform block

{- | Writes a sequence of byte lines to a file, each followed by a newline, one at
a time so neither the whole text nor a whole-file `BS.concat` is built (RFC-0040):
byte-identical to @BS.writeFile path (BS.pack (unlines ...))@ but constant-space in
the number of lines. The lines are consumed lazily, so a caller can generate them
on demand. A file that will not open is a 'StreamSourceError'; a write failure
part-way propagates as the exception it is, with the handle closed, and leaves a
partial file (the caller renames only on success).
-}
writeFileLines :: FilePath -> [BS.ByteString] -> IO (Either StreamError ())
writeFileLines path linesToWrite = do
    opened <- Open.openBinaryFileM path Base.WriteMode
    case opened of
        Nothing -> pure (Left (StreamSourceError ("cannot open file: " ++ path)))
        Just handle -> do
            Exception.finally
                (mapM_ (\line -> BS.hPut handle line >> BS.hPut handle newlineByte) linesToWrite)
                (Base.hClose handle)
            pure (Right ())

-- | A single newline byte, appended after each line by 'writeFileLines'.
newlineByte :: BS.ByteString
newlineByte = BS.singleton 10

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
compared a block at a time by a two-source consumer (RFC-0041): the first file
is its inner stream and the second its outer, each fed by its own
'fileEnumeratorChunked' bracket, so both handles are closed however the compare
stops. The blocks align because both readers ask for 'compareBlockBytes' from
files of equal size. Replaces reading both files into memory to compare them
(asset de-duplication and move conflict checks, RFC-0040). A file that cannot be
stat-ed or opened is a failure, not a verdict.
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
            | otherwise -> Iteratee.runNested2 (fileEnumeratorChunked compareBlockBytes pathA) (fileEnumeratorChunked compareBlockBytes pathB) equalBlocks

{- | The lock-step compare: one block from each stream per step, equal until
both end together; a block that differs, or one stream ending first, is a
verdict of not equal.
-}
equalBlocks :: Iteratee.IterT StreamError (Iteratee.IterT StreamError IO) Bool
equalBlocks = do
    blockA <- Iteratee.headChunk
    blockB <- Iteratee.lift Iteratee.headChunk
    case (blockA, blockB) of
        (Nothing, Nothing) -> pure True
        (Just a, Just b)
            | a == b -> equalBlocks
            | otherwise -> pure False
        _ -> pure False

-- | The block size for the streamed comparison.
compareBlockBytes :: Int
compareBlockBytes = 65536
