module MicroHttp.Http.ParserSpec(spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Http.Parser
import Test.Hspec

spec :: Spec
spec =
  describe "MicroHttp.Http.Parser" $ do
    it "given GET request, when parsing, then request fields are returned" $
      parseRequest
        defaultParseLimits
        (bs "GET /todos/open%20items?filter=open%20now HTTP/1.1\r\nHost: localhost\r\n\r\n")
        `shouldBe` Right Request
      { requestMethod = GET
      , requestPath = ["todos", "open items"]
      , requestQuery = [("filter", "open now")]
      , requestHeaders = [(normaliseHeaderName (bs "Host"), bs "localhost")]
      , requestBody = bs ""
      , requestRawPath = bs "/todos/open%20items"
      }
    it "given POST request with content length, when parsing, then request body is returned" $
      parseRequest
        defaultParseLimits
        (bs "POST /todos HTTP/1.1\r\nContent-Length: 11\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\ntitle=Helloignored")
        `shouldBe` Right Request
      { requestMethod = POST
      , requestPath = ["todos"]
      , requestQuery = []
      , requestHeaders =
          [ (normaliseHeaderName (bs "Content-Length"), bs "11")
          , (normaliseHeaderName (bs "Content-Type"), bs "application/x-www-form-urlencoded")
          ]
      , requestBody = bs "title=Hello"
      , requestRawPath = bs "/todos"
      }
    it "given unsupported method, when parsing, then unsupported method error is returned" $
      parseRequest defaultParseLimits (bs "PROPFIND /todos HTTP/1.1\r\n\r\n")
        `shouldBe` Left (UnsupportedMethod (bs "PROPFIND"))
    it "given unsupported HTTP version, when parsing, then unsupported version error is returned" $
      parseRequest defaultParseLimits (bs "GET /todos HTTP/2.0\r\n\r\n")
        `shouldBe` Left UnsupportedHttpVersion
    it "given malformed request line, when parsing, then bad request error is returned" $
      parseRequest defaultParseLimits (bs "GET /todos\r\n\r\n")
        `shouldBe` Left (BadRequest "invalid request line")
    it "given oversized headers, when parsing, then header too large error is returned" $
      parseRequest (ParseLimits 4 100) (bs "GET / HTTP/1.1\r\n\r\n")
        `shouldBe` Left HeaderTooLarge
    it "given oversized body, when parsing, then body too large error is returned" $
      parseRequest (ParseLimits 1000 4) (bs "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")
        `shouldBe` Left BodyTooLarge
    it "given chunked transfer encoding, when parsing, then unsupported transfer encoding is returned" $
      parseRequest defaultParseLimits (bs "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
        `shouldBe` Left UnsupportedTransferEncoding

bs :: String -> BS.ByteString
bs = BS.pack
