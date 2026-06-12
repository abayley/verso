module Main (main) where

import qualified MicroHttp.Http.ResponseFileSpec as ResponseFileSpec
import qualified MicroHttp.Network.SocketSpec as SocketSpec
import qualified MicroHttp.ServerConcurrencySpec as ServerConcurrencySpec
import qualified MicroHttp.ServerLoggingSpec as ServerLoggingSpec
import qualified MicroHttp.ServerSocketSpec as ServerSocketSpec
import qualified MicroHttp.StreamSpec as StreamSpec
import qualified MicroHttp.TestAppSpec as TestAppSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hspec $ do
        ResponseFileSpec.spec
        SocketSpec.spec
        ServerConcurrencySpec.spec
        ServerLoggingSpec.spec
        ServerSocketSpec.spec
        StreamSpec.spec
        TestAppSpec.spec
