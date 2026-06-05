module Main(main) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp

main :: IO ()
main =
  assertEqual
    "given public facade import, when building response, then exported modules are available"
    (StrictBody (BS.pack "<p>hello</p>"))
    (responseBody (Response okStatus [] (StrictBody (BS.pack (renderHtml page)))))

page :: Html ()
page =
  el "p" [] (text "hello")

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual then
    return ()
  else
    error (name ++ ": expected " ++ show expected ++ ", got " ++ show actual)
