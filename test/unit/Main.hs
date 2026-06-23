module Main (main) where

import qualified MicroHttp.AttachmentSpec as AttachmentSpec
import qualified MicroHttp.ClientErrorSpec as ClientErrorSpec
import qualified MicroHttp.ConfigSpec as ConfigSpec
import qualified MicroHttp.DocumentLinksSpec as DocumentLinksSpec
import qualified MicroHttp.DocumentListingSpec as DocumentListingSpec
import qualified MicroHttp.DocumentMetaSpec as DocumentMetaSpec
import qualified MicroHttp.FileOpsSpec as FileOpsSpec
import qualified MicroHttp.HtmlSpec as HtmlSpec
import qualified MicroHttp.Http.FramingSpec as FramingSpec
import qualified MicroHttp.Http.ParserSpec as ParserSpec
import qualified MicroHttp.Http.ResponseSpec as ResponseSpec
import qualified MicroHttp.HttpSpec as HttpSpec
import qualified MicroHttp.IterateeSpec as IterateeSpec
import qualified MicroHttp.LogSpec as LogSpec
import qualified MicroHttp.MiddlewareSpec as MiddlewareSpec
import qualified MicroHttp.Network.SocketAddrSpec as SocketAddrSpec
import qualified MicroHttp.OperationLogSpec as OperationLogSpec
import qualified MicroHttp.RouterSpec as RouterSpec
import qualified MicroHttp.ServerSpec as ServerSpec
import qualified MicroHttp.StaticSpec as StaticSpec
import qualified MicroHttp.TestAppSpec as TestAppSpec
import qualified MicroHttp.TrashSpec as TrashSpec
import qualified MicroHttp.TreeMoveSpec as TreeMoveSpec
import qualified MicroHttpSpec as FacadeSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
    FacadeSpec.spec
    AttachmentSpec.spec
    ClientErrorSpec.spec
    ConfigSpec.spec
    DocumentLinksSpec.spec
    DocumentListingSpec.spec
    DocumentMetaSpec.spec
    FileOpsSpec.spec
    FramingSpec.spec
    HtmlSpec.spec
    HttpSpec.spec
    ParserSpec.spec
    ResponseSpec.spec
    RouterSpec.spec
    ServerSpec.spec
    StaticSpec.spec
    TrashSpec.spec
    TreeMoveSpec.spec
    IterateeSpec.spec
    LogSpec.spec
    MiddlewareSpec.spec
    SocketAddrSpec.spec
    OperationLogSpec.spec
    TestAppSpec.spec
