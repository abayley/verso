module Main (main) where

import qualified MicroHttp.AttachmentSpec as AttachmentSpec
import qualified MicroHttp.ClientErrorSpec as ClientErrorSpec
import qualified MicroHttp.ConfigSpec as ConfigSpec
import qualified MicroHttp.DocumentLinksSpec as DocumentLinksSpec
import qualified MicroHttp.DocumentListingSpec as DocumentListingSpec
import qualified MicroHttp.DocumentMetaSpec as DocumentMetaSpec
import qualified MicroHttp.FileSystemSpec as FileSystemSpec
import qualified MicroHttp.HtmlSpec as HtmlSpec
import qualified MicroHttp.Http.FramingSpec as FramingSpec
import qualified MicroHttp.Http.ParserSpec as ParserSpec
import qualified MicroHttp.Http.ResponseSpec as ResponseSpec
import qualified MicroHttp.HttpSpec as HttpSpec
import qualified MicroHttp.IterateeSpec as IterateeSpec
import qualified MicroHttp.LinkFingerprintSpec as LinkFingerprintSpec
import qualified MicroHttp.LinkIndexSpec as LinkIndexSpec
import qualified MicroHttp.LinkIndexStoreSpec as LinkIndexStoreSpec
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
import qualified Verso.ConfigSpec as VersoConfigSpec

main :: IO ()
main = hspec $ do
    FacadeSpec.spec
    AttachmentSpec.spec
    ClientErrorSpec.spec
    ConfigSpec.spec
    DocumentLinksSpec.spec
    DocumentListingSpec.spec
    DocumentMetaSpec.spec
    FileSystemSpec.spec
    FramingSpec.spec
    HtmlSpec.spec
    LinkFingerprintSpec.spec
    LinkIndexSpec.spec
    LinkIndexStoreSpec.spec
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
    VersoConfigSpec.spec
