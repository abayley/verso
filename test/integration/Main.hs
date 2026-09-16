module Main (main) where

import qualified Concordance.SearchSeamSpec as SearchSeamSpec
import qualified Concordance.WordPieceFixtureSpec as WordPieceFixtureSpec
import qualified MicroHttp.ConfigSpec as ConfigSpec
import qualified MicroHttp.Http.ResponseFileSpec as ResponseFileSpec
import qualified MicroHttp.Network.SocketSpec as SocketSpec
import qualified MicroHttp.ServerConcurrencySpec as ServerConcurrencySpec
import qualified MicroHttp.ServerLoggingSpec as ServerLoggingSpec
import qualified MicroHttp.ServerSocketSpec as ServerSocketSpec
import qualified MicroHttp.StaticSpec as StaticSpec
import qualified MicroHttp.StreamSpec as StreamSpec
import qualified System.IO as IO
import Test.Hspec
import qualified Verso.AppSpec as AppSpec
import qualified Verso.GitSpec as GitSpec
import qualified Verso.OperationStoreSpec as OperationStoreSpec
import qualified Verso.SearchAppSpec as SearchAppSpec
import qualified Verso.StructureSpec as StructureSpec
import qualified Verso.TrashStoreSpec as TrashStoreSpec

main :: IO ()
main = do
    IO.hSetBuffering IO.stdout IO.LineBuffering
    hspec $ do
        WordPieceFixtureSpec.spec
        SearchSeamSpec.spec
        ConfigSpec.spec
        ResponseFileSpec.spec
        SocketSpec.spec
        ServerConcurrencySpec.spec
        ServerLoggingSpec.spec
        ServerSocketSpec.spec
        StaticSpec.spec
        StreamSpec.spec
        GitSpec.spec
        OperationStoreSpec.spec
        AppSpec.spec
        SearchAppSpec.spec
        TrashStoreSpec.spec
        StructureSpec.spec
