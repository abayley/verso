module Verso.ClientErrorSpec (spec) where

import qualified Control.Concurrent.MVar as MVar
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Router as Router
import Test.Hspec
import qualified Verso.App as App

spec :: Spec
spec =
    describe "Verso.App client-error endpoint (RFC-0023)" $ do
        it "given a report, when posted, then it records one logfmt line and returns 204" $ do
            (status, recorded) <- postClientError "message=boom&stack=at+foo&path=/documents/x&kind=error"
            Http.statusCode status `shouldBe` 204
            length recorded `shouldBe` 1
            let line = head recorded
            ("event=CLERR" `List.isInfixOf` line) `shouldBe` True
            ("kind=error" `List.isInfixOf` line) `shouldBe` True
            ("message=\"boom\"" `List.isInfixOf` line) `shouldBe` True
            ("path=\"/documents/x\"" `List.isInfixOf` line) `shouldBe` True

        it "given a crafted message with a newline and a fake field, when posted, then it stays one escaped line" $ do
            -- message decodes to: evil<newline> event=INJECT x -- a logfmt-injection attempt.
            (status, recorded) <- postClientError "message=evil%0A event%3DINJECT%20x&kind=error"
            Http.statusCode status `shouldBe` 204
            length recorded `shouldBe` 1
            let line = head recorded
            ('\n' `elem` line) `shouldBe` False
            ("evil\\n" `List.isInfixOf` line) `shouldBe` True

        it "given an unknown kind, when posted, then it is recorded as unknown" $ do
            (_, recorded) <- postClientError "message=x&kind=whatever"
            ("kind=unknown" `List.isInfixOf` head recorded) `shouldBe` True

-- | Posts a urlencoded body to the client-error route with a capturing sink, returning the status and lines.
postClientError :: String -> IO (Http.Status, [String])
postClientError body = do
    sinkVar <- MVar.newMVar []
    let sink line = MVar.modifyMVar_ sinkVar (\recorded -> pure (recorded ++ [line]))
        request = Http.emptyRequestHead{Http.requestMethod = Http.POST, Http.requestPath = ["client-errors"]}
    outcome <- Iteratee.strictEnumerator (BS.pack body) (Router.route [App.clientErrorRoute sink] request) >>= Iteratee.run
    recorded <- MVar.readMVar sinkVar
    case outcome of
        Right response -> pure (Http.responseStatus response, recorded)
        Left err -> do
            ("stream failure: " ++ show err) `shouldBe` "no stream failure"
            pure (Http.Status 0 "", recorded)
