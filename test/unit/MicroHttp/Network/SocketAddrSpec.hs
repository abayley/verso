module MicroHttp.Network.SocketAddrSpec (spec) where

import MicroHttp.Network.Socket
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Network.Socket address encoding" $ do
        it "given an IPv4 host and port, when encoding, then the sixteen sockaddr_in bytes are returned" $ do
            encodeSockAddrIn (HostIPv4 127 0 0 1) (Port 8080)
                `shouldBe` [16, 2, 31, 144, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        it "given the any host, when encoding, then the address bytes are zero" $ do
            encodeSockAddrIn HostAny (Port 80)
                `shouldBe` [16, 2, 0, 80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
