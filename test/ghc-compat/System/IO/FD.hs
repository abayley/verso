{- | GHC stand-in for MicroHs's @System.IO.FD@ (the scheduler's
file-descriptor wait primitives, used by 'MicroHttp.Network.Socket'):
GHC's IO manager provides the same operations as
'GHC.Conc.threadWaitRead' / 'GHC.Conc.threadWaitWrite'.
-}
module System.IO.FD (
    waitForReadFD,
    waitForWriteFD,
) where

import qualified GHC.Conc as Conc
import qualified System.Posix.Types as Types

waitForReadFD :: Int -> IO ()
waitForReadFD = Conc.threadWaitRead . Types.Fd . fromIntegral

waitForWriteFD :: Int -> IO ()
waitForWriteFD = Conc.threadWaitWrite . Types.Fd . fromIntegral
