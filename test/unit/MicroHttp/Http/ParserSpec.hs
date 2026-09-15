module MicroHttp.Http.ParserSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Http as Http
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Http.Parser" $ do
        it "given a GET header block, when parsing the head, then the head fields are returned" $
            Http.parseRequestHead
                (bs "GET /todos/open%20items?filter=open%20now HTTP/1.1\r\nHost: localhost")
                `shouldBe` Right
                    Http.emptyRequestHead
                        { Http.requestMethod = Http.GET
                        , Http.requestPath = ["todos", "open items"]
                        , Http.requestQuery = [("filter", "open now")]
                        , Http.requestHeaders = [(Http.normaliseHeaderName (bs "Host"), bs "localhost")]
                        , Http.requestRawPath = bs "/todos/open%20items"
                        }
        it "given a POST header block, when parsing the head, then headers are returned without a body field" $
            Http.parseRequestHead
                (bs "POST /todos HTTP/1.1\r\nContent-Length: 11\r\nContent-Type: application/x-www-form-urlencoded")
                `shouldBe` Right
                    Http.emptyRequestHead
                        { Http.requestMethod = Http.POST
                        , Http.requestPath = ["todos"]
                        , Http.requestQuery = []
                        , Http.requestHeaders =
                            [ (Http.normaliseHeaderName (bs "Content-Length"), bs "11")
                            , (Http.normaliseHeaderName (bs "Content-Type"), bs "application/x-www-form-urlencoded")
                            ]
                        , Http.requestRawPath = bs "/todos"
                        }
        it "given unsupported method, when parsing the head, then unsupported method error is returned" $
            Http.parseRequestHead (bs "PROPFIND /todos HTTP/1.1")
                `shouldBe` Left (Http.UnsupportedMethod (bs "PROPFIND"))
        it "given unsupported HTTP version, when parsing the head, then unsupported version error is returned" $
            Http.parseRequestHead (bs "GET /todos HTTP/2.0")
                `shouldBe` Left Http.UnsupportedHttpVersion
        it "given malformed request line, when parsing the head, then bad request error is returned" $
            Http.parseRequestHead (bs "GET /todos")
                `shouldBe` Left (Http.BadRequest "invalid request line")
        it "given chunked transfer encoding, when parsing the head, then unsupported transfer encoding is returned" $
            Http.parseRequestHead (bs "POST / HTTP/1.1\r\nTransfer-Encoding: chunked")
                `shouldBe` Left Http.UnsupportedTransferEncoding
        it "given a plus in a path segment, when parsing the head, then the plus is kept literally" $
            fmap Http.requestPath (Http.parseRequestHead (bs "GET /a+b/c HTTP/1.1"))
                `shouldBe` Right ["a+b", "c"]
        it "given a percent-encoded plus in a path segment, when parsing the head, then it decodes to a plus" $
            fmap Http.requestPath (Http.parseRequestHead (bs "GET /a%2Bb HTTP/1.1"))
                `shouldBe` Right ["a+b"]
        it "given percent-encoded UTF-8 in the path and the query, when parsed, then the segments and values are real characters (RFC-0043)" $ do
            let parsed = Http.parseRequestHead (bs "GET /documents/caf%C3%A9%20%E2%80%94%20%D0%96.md?to=%D0%96&x=%C3%A9 HTTP/1.1")
            fmap Http.requestPath parsed `shouldBe` Right ["documents", "caf\233 \8212 \1046.md"]
            fmap Http.requestQuery parsed `shouldBe` Right [("to", "\1046"), ("x", "\233")]
        it "given a plus in a query value, when parsing the head, then the plus decodes to a space" $
            fmap Http.requestQuery (Http.parseRequestHead (bs "GET /search?q=a+b HTTP/1.1"))
                `shouldBe` Right [("q", "a b")]

bs :: String -> BS.ByteString
bs = BS.pack
