module MicroHttp.Network.SocketAddrSpec (spec) where

import qualified MicroHttp.Network.Socket as Socket
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Network.Socket address encoding" $ do
        it "given an IPv4 host and port, when encoding, then the sixteen sockaddr_in bytes are returned" $ do
            Socket.encodeSockAddrIn (Socket.HostIPv4 127 0 0 1) (Socket.Port 8080)
                `shouldBe` [16, 2, 31, 144, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        it "given the any host, when encoding, then the address bytes are zero" $ do
            Socket.encodeSockAddrIn Socket.HostAny (Socket.Port 80)
                `shouldBe` [16, 2, 0, 80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
