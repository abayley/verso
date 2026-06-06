module Main(main) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp
import Test.Hspec

main :: IO ()
main = hspec $
  describe "MicroHttp facade" $
    it "given public facade import, when building response, then exported modules are available" $
      responseBody (Response okStatus [] (StrictBody (BS.pack (renderHtml page))))
        `shouldBe` StrictBody (BS.pack "<p>hello</p>")

page :: Html ()
page =
  el "p" [] (text "hello")
