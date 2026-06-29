module Verso.IdentitySpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Http as Http
import Test.Hspec
import qualified Verso.Git as Git
import qualified Verso.Identity as Identity

cfg :: Identity.IdentityConfig
cfg =
    Identity.IdentityConfig
        { Identity.idcHeader = "X-Remote-User"
        , Identity.idcDefault = "anonymous"
        , Identity.idcEmailDomain = "verso.local"
        }

-- | A request head carrying the given header name/value pairs.
headWith :: [(String, String)] -> Http.RequestHead
headWith pairs =
    Http.emptyRequestHead
        { Http.requestHeaders = map normalise pairs
        }
  where
    normalise (k, v) = (Http.normaliseHeaderName (BS.pack k), BS.pack v)

spec :: Spec
spec =
    describe "Verso.Identity" $ do
        describe "deriveIdentity" $ do
            it "uses the header value as the name and synthesises an email" $ do
                Identity.deriveIdentity cfg (Just "Alice")
                    `shouldBe` Git.Identity "Alice" "alice@verso.local"

            it "falls back to the default name when the header is absent" $ do
                Identity.deriveIdentity cfg Nothing
                    `shouldBe` Git.Identity "anonymous" "anonymous@verso.local"

            it "falls back to the default name when the header is blank" $ do
                Identity.deriveIdentity cfg (Just "   ")
                    `shouldBe` Git.Identity "anonymous" "anonymous@verso.local"

            it "slugs a multi-word name into the email local-part" $ do
                Git.identityEmail (Identity.deriveIdentity cfg (Just "Test Author"))
                    `shouldBe` "test-author@verso.local"

        describe "currentIdentity" $ do
            it "reads the configured header from the request, case-insensitively" $ do
                let req = headWith [("x-remote-user", "Bob")]
                Identity.currentIdentity cfg req
                    `shouldBe` Git.Identity "Bob" "bob@verso.local"

            it "uses the default when the request has no identity header" $ do
                Identity.currentIdentity cfg (headWith [("user-agent", "curl")])
                    `shouldBe` Git.Identity "anonymous" "anonymous@verso.local"
