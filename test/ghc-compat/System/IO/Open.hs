module System.IO.Open (
    openBinaryFileM,
) where

import Control.Exception (IOException, try)
import System.IO (Handle, IOMode, openBinaryFile)

openBinaryFileM :: FilePath -> IOMode -> IO (Maybe Handle)
openBinaryFileM path mode = do
    opened <- try (openBinaryFile path mode)
    case opened of
        Left (_ :: IOException) -> return Nothing
        Right handle -> return (Just handle)
