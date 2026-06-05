module Main(main) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http

main :: IO ()
main = do
  assertEqual
    "given GET token, when parsing method, then GET constructor is returned"
    (Just GET)
    (parseMethod (bs "GET"))
  assertEqual
    "given extension method token, when parsing method, then method is rejected"
    Nothing
    (parseMethod (bs "PROPFIND"))
  assertEqual
    "given POST token, when parsing method, then POST constructor is returned"
    (Just POST)
    (parseMethod (bs "POST"))
  assertEqual
    "given mixed-case header name, when normalising, then lower-case name is returned"
    (HeaderName (bs "content-type"))
    (normaliseHeaderName (bs "Content-Type"))
  assertEqual
    "given strict body response, when reading response body, then strict body is visible"
    (StrictBody (bs "hello"))
    (responseBody (Response okStatus [] (StrictBody (bs "hello"))))
  assertEqual
    "given file body response, when reading response body, then file path is visible"
    (FileBody "public/app.css")
    (responseBody (Response okStatus [] (FileBody "public/app.css")))

bs :: String -> BS.ByteString
bs = BS.pack

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual then
    return ()
  else
    error (name ++ ": expected " ++ show expected ++ ", got " ++ show actual)
