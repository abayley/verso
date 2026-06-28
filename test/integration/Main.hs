module Main (main) where

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

main :: IO ()
main = do
    IO.hSetBuffering IO.stdout IO.LineBuffering
    hspec $ do
        ConfigSpec.spec
        ResponseFileSpec.spec
        SocketSpec.spec
        ServerConcurrencySpec.spec
        ServerLoggingSpec.spec
        ServerSocketSpec.spec
        StaticSpec.spec
        StreamSpec.spec
        AppSpec.spec
