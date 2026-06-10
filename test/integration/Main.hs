module Main (main) where

import qualified MicroHttp.Http.ResponseFileSpec as ResponseFileSpec
import qualified MicroHttp.Network.SocketSpec as SocketSpec
import qualified MicroHttp.TestAppSpec as TestAppSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hspec $ do
        ResponseFileSpec.spec
        SocketSpec.spec
        TestAppSpec.spec
