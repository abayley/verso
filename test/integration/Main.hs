module Main(main) where

import qualified MicroHttp.Http.ResponseFileSpec as ResponseFileSpec
import qualified MicroHttp.Network.SocketSpec as SocketSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  ResponseFileSpec.spec
  SocketSpec.spec
