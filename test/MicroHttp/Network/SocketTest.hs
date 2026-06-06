module Main(main) where

import MicroHttp.Network.Socket
import Test.Hspec

main :: IO ()
main = hspec $
  describe "MicroHttp.Network.Socket" $
    it "given port zero, when listening and closing, then both operations succeed" $ do
      opened <- listenTcp HostAny (Port 0) 1
      case opened of
        Left err ->
          expect ("listenTcp failed: " ++ show err) False
        Right socket -> do
          closed <- closeListenSocket socket
          closed `shouldBe` Right ()
