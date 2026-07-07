{- | GHC stand-in for MicroHs's @System.IO.TimeMilli@ (wall-clock milliseconds,
used by 'MicroHttp.Log' timestamps and 'MicroHttp.Middleware' timings), via the
@time@ package's POSIX clock.
-}
module System.IO.TimeMilli (
    getTimeMilli,
) where

import qualified Data.Time.Clock.POSIX as POSIX

getTimeMilli :: IO Int
getTimeMilli = fmap (round . (* 1000)) POSIX.getPOSIXTime
