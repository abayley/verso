module Main (main) where

import qualified MicroHttp.HtmlSpec as HtmlSpec
import qualified MicroHttp.Http.ParserSpec as ParserSpec
import qualified MicroHttp.Http.ResponseSpec as ResponseSpec
import qualified MicroHttp.HttpSpec as HttpSpec
import qualified MicroHttp.RouterSpec as RouterSpec
import qualified MicroHttp.ServerSpec as ServerSpec
import qualified MicroHttp.TestAppSpec as TestAppSpec
import qualified MicroHttpSpec as FacadeSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
    FacadeSpec.spec
    HtmlSpec.spec
    HttpSpec.spec
    ParserSpec.spec
    ResponseSpec.spec
    RouterSpec.spec
    ServerSpec.spec
    TestAppSpec.spec
