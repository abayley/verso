{- | Percent-decoding a path segment or query value, the shape the request path
takes: many short strings, not one large body (@FormDecodeBench@ covers the body).

Compares the shared byte decoder reached through the @String@ wrapper
('Http.decodeFormValue', which packs and unpacks around 'MicroHttp.Percent')
against a @String@-native decoder of the same semantics, so the cost of the
bytes/@String@ round trip is visible on its own. Under MicroHs @unpack@ is strict
and builds the whole list in C, so that round trip is not free.
-}
module Main (main) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Percent as Percent
import qualified System.CPUTime as CPUTime

main :: IO ()
main = do
    putStrLn ("segments = " ++ show (length corpus) ++ ", reps = " ++ show reps)
    putStrLn "strategy         | total ms | us/segment"
    bench "shared (bytes)" Http.decodeFormValue
    bench "String-native " stringNative
    putStrLn ""
    putStrLn ("body = " ++ show (BS.length body) ++ " bytes, reps = " ++ show blockReps)
    putStrLn "block decoder    | total ms | ms/decode"
    benchBlock "shared        " (fst . Percent.decodeBlock Percent.PlusIsSpace)
    benchBlock "skip-3 (before)" (fst . oldBlock)

-- | Request-shaped inputs: real path segments and query values, all short.
corpus :: [String]
corpus =
    concat
        (replicate 200 ["documents", "guides", "failover.md", "a+b", "caf%C3%A9", "My+Page+Title", "q=1", "%23heading", "plain-segment", "x%2Fy"])

reps :: Int
reps = 20

bench :: String -> (String -> String) -> IO ()
bench name f = do
    start <- CPUTime.getCPUTime
    total <- loop reps 0
    -- Forced before the end time is read: the accumulator is lazy, so an
    -- unforced total would move every decode after the measurement.
    end <- total `seq` CPUTime.getCPUTime
    let ms = fromIntegral (end - start) / 1000000000 :: Double
        perSeg = ms * 1000 / fromIntegral (reps * length corpus)
    putStrLn (name ++ " | " ++ pad 8 (showMs ms) ++ " | " ++ showMs perSeg ++ "   [" ++ show total ++ "]")
  where
    -- The decoded lengths are summed so the work cannot be dropped.
    loop 0 acc = pure acc
    loop n acc = let acc' = acc + sum (map (length . f) corpus) in acc' `seq` loop (n - 1 :: Int) acc'

showMs :: Double -> String
showMs x = show (fromIntegral (round (x * 100) :: Int) / 100 :: Double)

pad :: Int -> String -> String
pad n s = s ++ replicate (max 0 (n - length s)) ' '

{- | The decoder Http had before the byte decoder was shared, with the WHATWG
recovery rule: a @%@ that does not begin a valid escape is emitted as itself and
the scan moves on by one.
-}
stringNative :: String -> String
stringNative [] = []
stringNative ('%' : a : b : rest)
    | Char.isHexDigit a && Char.isHexDigit b =
        Char.chr (Char.digitToInt a * 16 + Char.digitToInt b) : stringNative rest
stringNative ('+' : rest) = ' ' : stringNative rest
stringNative (c : rest) = c : stringNative rest

-- | A form-value-shaped body: prose with escapes, as a routed part carries.
body :: BS.ByteString
body = BS.concat (replicate 400 (BS.pack "%23+Heading%0A%0AText+with+caf%C3%A9%2C+100%25+sure%3F%0A"))

blockReps :: Int
blockReps = 20

benchBlock :: String -> (BS.ByteString -> BS.ByteString) -> IO ()
benchBlock name f = do
    start <- CPUTime.getCPUTime
    total <- loop blockReps 0
    end <- total `seq` CPUTime.getCPUTime
    let ms = fromIntegral (end - start) / 1000000000 :: Double
    putStrLn (name ++ " | " ++ pad 8 (showMs ms) ++ " | " ++ showMs (ms / fromIntegral blockReps) ++ "   [" ++ show total ++ "]")
  where
    loop 0 acc = pure acc
    loop n acc = let acc' = acc + BS.length (f body) in acc' `seq` loop (n - 1 :: Int) acc'

{- | The block decoder before the WHATWG recovery rule: a malformed escape's
three bytes were all emitted and the scan skipped past them, so the escape in
@%%41@ did not decode. Kept here only to price the change.
-}
oldBlock :: BS.ByteString -> (BS.ByteString, BS.ByteString)
oldBlock bytes = (BS.pack (go 0), BS.drop cut bytes)
  where
    len = BS.length bytes
    cut = scan 0
    scan i
        | i >= len = len
        | BS.index bytes i /= '%' = scan (i + 1)
        | i + 2 < len = scan (i + 3)
        | otherwise = i
    go i
        | i >= cut = []
        | c == '+' = ' ' : go (i + 1)
        | c == '%' =
            if Char.isHexDigit (BS.index bytes (i + 1)) && Char.isHexDigit (BS.index bytes (i + 2))
                then Char.chr (Char.digitToInt (BS.index bytes (i + 1)) * 16 + Char.digitToInt (BS.index bytes (i + 2))) : go (i + 3)
                else c : BS.index bytes (i + 1) : BS.index bytes (i + 2) : go (i + 3)
        | otherwise = c : go (i + 1)
      where
        c = BS.index bytes i
