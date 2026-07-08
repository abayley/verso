module Main (main) where

import qualified Concordance.FingerprintSpec as FingerprintSpec
import qualified Concordance.FuseSpec as FuseSpec
import qualified Concordance.WordPieceSpec as WordPieceSpec
import qualified MicroHttp.ConfigSpec as ConfigSpec
import qualified MicroHttp.FileSystemSpec as FileSystemSpec
import qualified MicroHttp.HtmlSpec as HtmlSpec
import qualified MicroHttp.Http.FramingSpec as FramingSpec
import qualified MicroHttp.Http.ParserSpec as ParserSpec
import qualified MicroHttp.Http.ResponseSpec as ResponseSpec
import qualified MicroHttp.HttpSpec as HttpSpec
import qualified MicroHttp.IterateeSpec as IterateeSpec
import qualified MicroHttp.LogSpec as LogSpec
import qualified MicroHttp.MiddlewareSpec as MiddlewareSpec
import qualified MicroHttp.Network.SocketAddrSpec as SocketAddrSpec
import qualified MicroHttp.ProcessSpec as ProcessSpec
import qualified MicroHttp.RouterSpec as RouterSpec
import qualified MicroHttp.ServerSpec as ServerSpec
import qualified MicroHttp.StaticSpec as StaticSpec
import qualified MicroHttpSpec as FacadeSpec
import Test.Hspec
import qualified Verso.AppSpec as AppSpec
import qualified Verso.AttachmentSpec as AttachmentSpec
import qualified Verso.ChromeSpec as ChromeSpec
import qualified Verso.ClientErrorSpec as ClientErrorSpec
import qualified Verso.ConfigSpec as VersoConfigSpec
import qualified Verso.DocumentLinksSpec as DocumentLinksSpec
import qualified Verso.DocumentListingSpec as DocumentListingSpec
import qualified Verso.DocumentMetaSpec as DocumentMetaSpec
import qualified Verso.DraftSpec as DraftSpec
import qualified Verso.IdentitySpec as IdentitySpec
import qualified Verso.LinkFingerprintSpec as LinkFingerprintSpec
import qualified Verso.LinkIndexSpec as LinkIndexSpec
import qualified Verso.LinkIndexStoreSpec as LinkIndexStoreSpec
import qualified Verso.OperationLogSpec as OperationLogSpec
import qualified Verso.SearchChunksSpec as SearchChunksSpec
import qualified Verso.SearchQueueSpec as SearchQueueSpec
import qualified Verso.TrashSpec as TrashSpec
import qualified Verso.TreeMoveSpec as TreeMoveSpec

main :: IO ()
main = hspec $ do
    FingerprintSpec.spec
    FuseSpec.spec
    WordPieceSpec.spec
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
    SearchChunksSpec.spec
    SearchQueueSpec.spec
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
    ProcessSpec.spec
    DraftSpec.spec
    IdentitySpec.spec
    OperationLogSpec.spec
    AppSpec.spec
    ChromeSpec.spec
    VersoConfigSpec.spec
