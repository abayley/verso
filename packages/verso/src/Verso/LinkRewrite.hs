{- | Rewrites a page's links in place as a stream (RFC-0039): each chunk is scanned
with the shared 'DocumentLinks.scanChunk' core, the links it settles are put to a
per-link decision, the settled bytes are spliced with the replacements and written
to a temporary file, and the temporary file is renamed over the original once the
whole page is through. Resident memory is one chunk plus the scanner's bounded
carry, never the page; the rename makes the write atomic, so a crash mid-way
leaves the original intact; and because links are found in the very bytes being
rewritten, no offset can go stale between a scan and a write.
-}
module Verso.LinkRewrite (
    rewriteFileLinks,
    rewriteFileLinksChunked,
    rewriteLinksI,
) where

import qualified Control.Exception as Exception
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import qualified System.IO as IO
import qualified Verso.DocumentLinks as DocumentLinks

{- | Rewrites the links of the page at @path@ per @decide@ (a replacement target, or
'Nothing' to leave a link alone), streaming in 'rewriteChunkBytes' chunks. 'Right'
says whether anything changed; the file is untouched when nothing did or on failure.
-}
rewriteFileLinks :: (DocumentLinks.Link -> Maybe String) -> FilePath -> IO (Either String Bool)
rewriteFileLinks = rewriteFileLinksChunked rewriteChunkBytes

-- | 'rewriteFileLinks' with the chunk size chosen by the caller.
rewriteFileLinksChunked :: Int -> (DocumentLinks.Link -> Maybe String) -> FilePath -> IO (Either String Bool)
rewriteFileLinksChunked chunkBytes decide path = do
    attempt <- Exception.try (IO.withBinaryFile tmp IO.WriteMode rewriteInto)
    case attempt of
        Left err -> failed (show (err :: Exception.SomeException))
        Right (Left streamErr) -> failed (show streamErr)
        Right (Right False) -> discardTmp >> pure (Right False)
        Right (Right True) -> do
            renamed <- FileSystem.renamePath tmp path
            case renamed of
                Left err -> failed ("rename failed (" ++ show err ++ ")")
                Right () -> pure (Right True)
  where
    tmp = path ++ ".tmp"
    rewriteInto handle =
        Stream.fileEnumeratorChunked chunkBytes path (rewriteLinksI decide (BS.hPut handle)) >>= Iteratee.run
    failed reason = discardTmp >> pure (Left reason)
    discardTmp = do
        exists <- Directory.doesFileExist tmp
        Monad.when exists (Directory.removeFile tmp)

-- | The chunk size for streaming a page through the rewriter.
rewriteChunkBytes :: Int
rewriteChunkBytes = 65536

{- | The fused scan-and-rewrite as a stream consumer: per chunk, the links the scanner
settles are decided, the settled bytes spliced and handed to @write@. Completes with
whether any link was replaced.
-}
rewriteLinksI :: (DocumentLinks.Link -> Maybe String) -> (BS.ByteString -> IO ()) -> Iteratee.Iter e Bool
rewriteLinksI decide write = go DocumentLinks.initialScan False
  where
    go st changed = Iteratee.NeedInput (step st changed)
    step st changed stream = case stream of
        Iteratee.Chunk bytes
            | BS.null bytes -> go st changed
            | otherwise ->
                let scanned = DocumentLinks.scanChunk st bytes
                 in emit scanned changed (go (DocumentLinks.scannedState scanned))
        Iteratee.EndOfStream Nothing ->
            emit (DocumentLinks.scanFinishAll st) changed (`Iteratee.Done` stream)
        Iteratee.EndOfStream (Just err) -> Iteratee.IterFailed err stream
    emit scanned changed continue =
        let base = DocumentLinks.scannedBase scanned
            edits = DocumentLinks.editsWith decide (DocumentLinks.scannedLinks scanned)
            settled = DocumentLinks.scannedSettled scanned
            out
                | null edits = settled
                | otherwise = DocumentLinks.rewriteLinks settled [(s - base, e - base, r) | (s, e, r) <- edits]
            changed' = changed || not (null edits)
         in if BS.null out
                then continue changed'
                else Iteratee.IterM (write out >> pure (continue changed'))
