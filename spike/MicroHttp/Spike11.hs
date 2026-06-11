-- Spike 11: minimal MicroHs ByteString corruption reproducer.
--
-- Once any other thread has been forked, even one that does nothing and
-- exits immediately, forcing a sufficiently large lazily constructed
-- ByteString yields an empty value. The corrupt value is memoised, and
-- every forcing observer is affected (BS.length and useAsCStringLen were
-- both tested). Deleting the forkIO line makes the output correct, so the
-- single-threaded case is fine. The size boundary on the machine below is
-- between 1024 (correct) and 4096 (corrupt).
--
-- Observed with mhs 0.16.0.0 on macOS arm64, deterministic on every run.
--
--   Expected output:    Observed output:
--     1000                1000
--     5000                0
--
-- This is the root cause of the apparent deadlock in Spike10: the sender
-- there received length zero for its payload, sent nothing, and its
-- receiver polled forever.
--
-- Compile and run:
--   mhs spike/MicroHttp/Spike11.hs -ispike -o build/spike11 && build/spike11
module MicroHttp.Spike11 (main) where

import Control.Concurrent (forkIO)
import qualified Data.ByteString.Char8 as BS

main :: IO ()
main = do
    _ <- forkIO (return ())
    print (BS.length (BS.pack (replicate 1000 'x')))
    print (BS.length (BS.pack (replicate 5000 'y')))
