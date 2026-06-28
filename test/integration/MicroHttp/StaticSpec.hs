module MicroHttp.StaticSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Router as Router
import qualified MicroHttp.Static as Static
import qualified MicroHttp.Stream as Stream
import qualified System.Directory as Directory
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Static serving" $ do
        it "given an existing file under the root, when served, then a 200 returns its contents" $ do
            writeFile assetFile "static body!"
            result <- runRoute (request Http.GET ["assets", "static-asset.txt"])
            body <- collectResponseBody result
            Directory.removeFile assetFile
            fmap (Http.statusCode . Http.responseStatus) result `shouldBe` Right 200
            body `shouldBe` Right (BS.pack "static body!")
        it "given an existing file under the root, when served, then the file body carries its exact size" $ do
            writeFile assetFile "static body!"
            result <- runRoute (request Http.GET ["assets", "static-asset.txt"])
            Directory.removeFile assetFile
            fmap Http.responseBody result `shouldBe` Right (Http.FileBody "build/static-asset.txt" 12)
        it "given a missing file under the root, when served, then a 404 is returned" $ do
            result <- runRoute (request Http.GET ["assets", "no-such-file.txt"])
            fmap (Http.statusCode . Http.responseStatus) result `shouldBe` Right 404
        it "given a directory target, when served, then a 404 is returned" $ do
            result <- runRoute (request Http.GET ["assets"])
            fmap (Http.statusCode . Http.responseStatus) result `shouldBe` Right 404
        it "given a parent-directory traversal, when served, then a 404 is returned and nothing escapes the root" $ do
            result <- runRoute (request Http.GET ["assets", "..", "Makefile"])
            fmap (Http.statusCode . Http.responseStatus) result `shouldBe` Right 404
        it "given a component with an embedded separator, when served, then a 404 is returned" $ do
            result <- runRoute (request Http.GET ["assets", "a/b"])
            fmap (Http.statusCode . Http.responseStatus) result `shouldBe` Right 404

routes :: [Router.Route]
routes = [Static.static "/assets" "build"]

runRoute :: Http.RequestHead -> IO (Either Stream.StreamError Http.Response)
runRoute head = Iteratee.strictEnumerator (BS.pack "") (Router.route routes head) >>= Iteratee.run

{- | Collects a response body to bytes, draining a streaming body through a
byte sink that appends each chunk.
-}
collectResponseBody :: Either Stream.StreamError Http.Response -> IO (Either Stream.StreamError BS.ByteString)
collectResponseBody (Left err) = return (Left err)
collectResponseBody (Right response) =
    case Http.responseBody response of
        Http.StrictBody body -> return (Right body)
        Http.FileBody path _ -> Right <$> BS.readFile path
        Http.StreamBody enumerator -> do
            chunks <- IORef.newIORef []
            final <- enumerator (Iteratee.byteSinkI (\chunk -> IORef.modifyIORef' chunks (chunk :) >> return (Right ())))
            outcome <- Iteratee.run final
            collected <- IORef.readIORef chunks
            return (fmap (const (BS.concat (reverse collected))) outcome)

request :: Http.Method -> [String] -> Http.RequestHead
request method path =
    Http.emptyRequestHead
        { Http.requestMethod = method
        , Http.requestPath = path
        }

assetFile :: FilePath
assetFile = "build/static-asset.txt"
