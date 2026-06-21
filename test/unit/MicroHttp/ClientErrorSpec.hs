module MicroHttp.ClientErrorSpec (spec) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import qualified Data.ByteString.Char8 as BS
import Data.List (isInfixOf)
import MicroHttp.Http
import MicroHttp.Iteratee (run, strictEnumerator)
import qualified MicroHttp.Router as Router
import MicroHttp.TestApp (clientErrorRoute)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.TestApp client-error endpoint (RFC-0023)" $ do
        it "given a report, when posted, then it records one logfmt line and returns 204" $ do
            (status, recorded) <- postClientError "message=boom&stack=at+foo&path=/documents/x&kind=error"
            statusCode status `shouldBe` 204
            length recorded `shouldBe` 1
            let line = head recorded
            ("event=CLERR" `isInfixOf` line) `shouldBe` True
            ("kind=error" `isInfixOf` line) `shouldBe` True
            ("message=\"boom\"" `isInfixOf` line) `shouldBe` True
            ("path=\"/documents/x\"" `isInfixOf` line) `shouldBe` True

        it "given a crafted message with a newline and a fake field, when posted, then it stays one escaped line" $ do
            -- message decodes to: evil<newline> event=INJECT x -- a logfmt-injection attempt.
            (status, recorded) <- postClientError "message=evil%0A event%3DINJECT%20x&kind=error"
            statusCode status `shouldBe` 204
            length recorded `shouldBe` 1
            let line = head recorded
            ('\n' `elem` line) `shouldBe` False
            ("evil\\n" `isInfixOf` line) `shouldBe` True

        it "given an unknown kind, when posted, then it is recorded as unknown" $ do
            (_, recorded) <- postClientError "message=x&kind=whatever"
            ("kind=unknown" `isInfixOf` head recorded) `shouldBe` True

-- | Posts a urlencoded body to the client-error route with a capturing sink, returning the status and lines.
postClientError :: String -> IO (Status, [String])
postClientError body = do
    sinkVar <- newMVar []
    let sink line = modifyMVar_ sinkVar (\recorded -> pure (recorded ++ [line]))
        request = emptyRequestHead{requestMethod = POST, requestPath = ["client-errors"]}
    outcome <- strictEnumerator (BS.pack body) (Router.route [clientErrorRoute sink] request) >>= run
    recorded <- readMVar sinkVar
    case outcome of
        Right response -> pure (responseStatus response, recorded)
        Left err -> do
            ("stream failure: " ++ show err) `shouldBe` "no stream failure"
            pure (Status 0 "", recorded)
