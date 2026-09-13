-- | Test support: a per-spec scratch directory under @build/@, emptied on demand.
module TestSupport.Scratch (
    resetScratchDir,
) where

import qualified Control.Monad as Monad
import qualified System.Directory as Directory

{- | Empties the directory of its files (subdirectories are left alone) and
creates it if missing, so each IO test starts from a known state.
-}
resetScratchDir :: FilePath -> IO ()
resetScratchDir dir = do
    exists <- Directory.doesDirectoryExist dir
    Monad.when exists $ do
        names <- Directory.listDirectory dir
        mapM_ (\name -> Directory.removeFile (dir ++ "/" ++ name)) names
    Directory.createDirectoryIfMissing True dir
