module MicroHttp.StaticSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import MicroHttp.Http
import MicroHttp.Iteratee (byteSinkI, run, strictEnumerator)
import MicroHttp.Router (Route, route)
import MicroHttp.Static (static)
import MicroHttp.Stream (StreamError)
import System.Directory (removeFile)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Static serving" $ do
        it "given an existing file under the root, when served, then a 200 returns its contents" $ do
            writeFile assetFile "static body!"
            result <- runRoute (request GET ["assets", "static-asset.txt"])
            body <- collectResponseBody result
            removeFile assetFile
            fmap (statusCode . responseStatus) result `shouldBe` Right 200
            body `shouldBe` Right (BS.pack "static body!")
        it "given an existing file under the root, when served, then the file body carries its exact size" $ do
            writeFile assetFile "static body!"
            result <- runRoute (request GET ["assets", "static-asset.txt"])
            removeFile assetFile
            fmap responseBody result `shouldBe` Right (FileBody "build/static-asset.txt" 12)
        it "given a missing file under the root, when served, then a 404 is returned" $ do
            result <- runRoute (request GET ["assets", "no-such-file.txt"])
            fmap (statusCode . responseStatus) result `shouldBe` Right 404
        it "given a directory target, when served, then a 404 is returned" $ do
            result <- runRoute (request GET ["assets"])
            fmap (statusCode . responseStatus) result `shouldBe` Right 404
        it "given a parent-directory traversal, when served, then a 404 is returned and nothing escapes the root" $ do
            result <- runRoute (request GET ["assets", "..", "Makefile"])
            fmap (statusCode . responseStatus) result `shouldBe` Right 404
        it "given a component with an embedded separator, when served, then a 404 is returned" $ do
            result <- runRoute (request GET ["assets", "a/b"])
            fmap (statusCode . responseStatus) result `shouldBe` Right 404

routes :: [Route]
routes = [static "/assets" "build"]

runRoute :: RequestHead -> IO (Either StreamError Response)
runRoute head = strictEnumerator (BS.pack "") (route routes head) >>= run

{- | Collects a response body to bytes, draining a streaming body through a
byte sink that appends each chunk.
-}
collectResponseBody :: Either StreamError Response -> IO (Either StreamError BS.ByteString)
collectResponseBody (Left err) = return (Left err)
collectResponseBody (Right response) =
    case responseBody response of
        StrictBody body -> return (Right body)
        FileBody path _ -> Right <$> BS.readFile path
        StreamBody enumerator -> do
            chunks <- newIORef []
            final <- enumerator (byteSinkI (\chunk -> modifyIORef' chunks (chunk :) >> return (Right ())))
            outcome <- run final
            collected <- readIORef chunks
            return (fmap (const (BS.concat (reverse collected))) outcome)

request :: Method -> [String] -> RequestHead
request method path =
    emptyRequestHead
        { requestMethod = method
        , requestPath = path
        }

assetFile :: FilePath
assetFile = "build/static-asset.txt"
