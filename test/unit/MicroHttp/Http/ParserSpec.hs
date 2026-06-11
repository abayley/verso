module MicroHttp.Http.ParserSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import MicroHttp.Http
import MicroHttp.Http.Parser
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Parser" $ do
        it "given a GET header block, when parsing the head, then the head fields are returned" $
            parseRequestHead
                (bs "GET /todos/open%20items?filter=open%20now HTTP/1.1\r\nHost: localhost")
                `shouldBe` Right
                    RequestHead
                        { requestMethod = GET
                        , requestPath = ["todos", "open items"]
                        , requestQuery = [("filter", "open now")]
                        , requestHeaders = [(normaliseHeaderName (bs "Host"), bs "localhost")]
                        , requestRawPath = bs "/todos/open%20items"
                        }
        it "given a POST header block, when parsing the head, then headers are returned without a body field" $
            parseRequestHead
                (bs "POST /todos HTTP/1.1\r\nContent-Length: 11\r\nContent-Type: application/x-www-form-urlencoded")
                `shouldBe` Right
                    RequestHead
                        { requestMethod = POST
                        , requestPath = ["todos"]
                        , requestQuery = []
                        , requestHeaders =
                            [ (normaliseHeaderName (bs "Content-Length"), bs "11")
                            , (normaliseHeaderName (bs "Content-Type"), bs "application/x-www-form-urlencoded")
                            ]
                        , requestRawPath = bs "/todos"
                        }
        it "given unsupported method, when parsing the head, then unsupported method error is returned" $
            parseRequestHead (bs "PROPFIND /todos HTTP/1.1")
                `shouldBe` Left (UnsupportedMethod (bs "PROPFIND"))
        it "given unsupported HTTP version, when parsing the head, then unsupported version error is returned" $
            parseRequestHead (bs "GET /todos HTTP/2.0")
                `shouldBe` Left UnsupportedHttpVersion
        it "given malformed request line, when parsing the head, then bad request error is returned" $
            parseRequestHead (bs "GET /todos")
                `shouldBe` Left (BadRequest "invalid request line")
        it "given chunked transfer encoding, when parsing the head, then unsupported transfer encoding is returned" $
            parseRequestHead (bs "POST / HTTP/1.1\r\nTransfer-Encoding: chunked")
                `shouldBe` Left UnsupportedTransferEncoding

bs :: String -> BS.ByteString
bs = BS.pack
