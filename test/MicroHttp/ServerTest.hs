module Main(main) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Server
import Test.Hspec

main :: IO ()
main = hspec $
  describe "MicroHttp.Server" $ do
    it "given valid request bytes, when responding, then application response is returned" $ do
      ok <- respondToRequestBytes
        defaultSettings
        app
        (bs "GET /hello HTTP/1.1\r\n\r\n")
      responseBody ok `shouldBe` StrictBody (bs "hello")
    it "given parser failure, when responding, then bad request response is returned" $ do
      bad <- respondToRequestBytes
        defaultSettings
        app
        (bs "TRACE /hello HTTP/1.1\r\n\r\n")
      statusCode (responseStatus bad) `shouldBe` 400

app :: Application
app request =
  return (Response okStatus [] (StrictBody (bs (headOrEmpty (requestPath request)))))

headOrEmpty :: [String] -> String
headOrEmpty [] = ""
headOrEmpty (x:_) = x

bs :: String -> BS.ByteString
bs = BS.pack
