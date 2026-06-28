module MicroHttpSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp as MicroHttp
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp facade" $
        it "given public facade import, when building response, then exported modules are available" $
            MicroHttp.responseBody (MicroHttp.Response MicroHttp.okStatus [] (MicroHttp.StrictBody (BS.pack (MicroHttp.renderHtml page))))
                `shouldBe` MicroHttp.StrictBody (BS.pack "<p>hello</p>")

page :: MicroHttp.Html ()
page =
    MicroHttp.el "p" [] (MicroHttp.text "hello")
