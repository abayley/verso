module MicroHttp.Network.SocketAddrSpec (spec) where

import qualified Foreign.C.Error as Error
import qualified MicroHttp.Network.Socket as Socket
import Test.Hspec

spec :: Spec
spec = do
    describe "MicroHttp.Network.Socket address encoding" $ do
        it "given an IPv4 host and port, when encoding, then the sixteen sockaddr_in bytes are returned" $ do
            Socket.encodeSockAddrIn (Socket.HostIPv4 127 0 0 1) (Socket.Port 8080)
                `shouldBe` [16, 2, 31, 144, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        it "given the any host, when encoding, then the address bytes are zero" $ do
            Socket.encodeSockAddrIn Socket.HostAny (Socket.Port 80)
                `shouldBe` [16, 2, 0, 80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    -- The errno used to be dropped when showing a SocketError, so every failed bind
    -- reported the bare word "bind" -- address-in-use indistinguishable from a
    -- permission error. It is the one part of the message that says what to do next.
    describe "MicroHttp.Network.Socket error rendering" $ do
        it "given an address-in-use error, when shown, then the errno is named" $
            show (Socket.SocketError "bind" Error.eADDRINUSE)
                `shouldBe` "SocketError \"bind\" EADDRINUSE"
        it "given a permission error, when shown, then the errno is named" $
            show (Socket.SocketError "bind" Error.eACCES)
                `shouldBe` "SocketError \"bind\" EACCES"
        it "given an unnamed errno, when shown, then its number is reported" $
            show (Socket.SocketError "recv" (Error.Errno 12345))
                `shouldBe` "SocketError \"recv\" errno 12345"
