module Main (main) where

import qualified MicroHttp.AttachmentSpec as AttachmentSpec
import qualified MicroHttp.ConfigSpec as ConfigSpec
import qualified MicroHttp.DocumentMetaSpec as DocumentMetaSpec
import qualified MicroHttp.HtmlSpec as HtmlSpec
import qualified MicroHttp.Http.FramingSpec as FramingSpec
import qualified MicroHttp.Http.ParserSpec as ParserSpec
import qualified MicroHttp.Http.ResponseSpec as ResponseSpec
import qualified MicroHttp.HttpSpec as HttpSpec
import qualified MicroHttp.IterateeSpec as IterateeSpec
import qualified MicroHttp.LogSpec as LogSpec
import qualified MicroHttp.MiddlewareSpec as MiddlewareSpec
import qualified MicroHttp.Network.SocketAddrSpec as SocketAddrSpec
import qualified MicroHttp.RouterSpec as RouterSpec
import qualified MicroHttp.ServerSpec as ServerSpec
import qualified MicroHttp.StaticSpec as StaticSpec
import qualified MicroHttp.TestAppSpec as TestAppSpec
import qualified MicroHttpSpec as FacadeSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
    FacadeSpec.spec
    AttachmentSpec.spec
    ConfigSpec.spec
    DocumentMetaSpec.spec
    FramingSpec.spec
    HtmlSpec.spec
    HttpSpec.spec
    ParserSpec.spec
    ResponseSpec.spec
    RouterSpec.spec
    ServerSpec.spec
    StaticSpec.spec
    IterateeSpec.spec
    LogSpec.spec
    MiddlewareSpec.spec
    SocketAddrSpec.spec
    TestAppSpec.spec
