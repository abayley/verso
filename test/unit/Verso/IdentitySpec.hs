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
            it "given an identity header, when an identity is derived, then the header is the name and an email is synthesised" $ do
                Identity.deriveIdentity cfg (Just "Alice")
                    `shouldBe` Git.Identity "Alice" "alice@verso.local"

            it "given no identity header, when an identity is derived, then the default name is used" $ do
                Identity.deriveIdentity cfg Nothing
                    `shouldBe` Git.Identity "anonymous" "anonymous@verso.local"

            it "given a blank identity header, when an identity is derived, then the default name is used" $ do
                Identity.deriveIdentity cfg (Just "   ")
                    `shouldBe` Git.Identity "anonymous" "anonymous@verso.local"

            it "given a multi-word name, when an identity is derived, then the name is slugged into the email local-part" $ do
                Git.identityEmail (Identity.deriveIdentity cfg (Just "Test Author"))
                    `shouldBe` "test-author@verso.local"

        describe "currentIdentity" $ do
            it "given the configured header in any case, when the current identity is read, then it is found" $ do
                let req = headWith [("x-remote-user", "Bob")]
                Identity.currentIdentity cfg req
                    `shouldBe` Git.Identity "Bob" "bob@verso.local"

            it "given a request with no identity header, when the current identity is read, then the default is used" $ do
                Identity.currentIdentity cfg (headWith [("user-agent", "curl")])
                    `shouldBe` Git.Identity "anonymous" "anonymous@verso.local"
