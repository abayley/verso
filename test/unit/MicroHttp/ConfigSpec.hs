module MicroHttp.ConfigSpec (spec) where

import MicroHttp.Config
import MicroHttp.Network.Socket (Host (..), Port (..))
import MicroHttp.Server (Settings (..))
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Config" $ do
        describe "parseConfig" $ do
            it "given keys, comments, blanks, and whitespace, when parsing, then values are read trimmed" $ do
                let cfg = parsed "  port = 8080 \n# a comment\n\nhost=0.0.0.0\n"
                configString "host" "x" cfg `shouldBe` "0.0.0.0"
                configInt "port" 0 cfg `shouldBe` Right 8080
            it "given a non-blank line without an equals, when parsing, then it is an error" $
                isLeft (parseConfig "port = 8080\noops no equals") `shouldBe` True
        describe "typed lookups" $ do
            it "given an absent key, when looking up, then the default is returned" $ do
                configString "missing" "def" (parsed "") `shouldBe` "def"
                configInt "missing" 42 (parsed "") `shouldBe` Right 42
                configBool "missing" True (parsed "") `shouldBe` Right True
            it "given a non-numeric integer key, when looking up, then it is an error" $
                isLeft (configInt "port" 0 (parsed "port = eighty")) `shouldBe` True
            it "given a boolean key, when looking up, then true and false parse and anything else errors" $ do
                configBool "on" False (parsed "on = true") `shouldBe` Right True
                configBool "on" True (parsed "on = false") `shouldBe` Right False
                isLeft (configBool "on" False (parsed "on = yes")) `shouldBe` True
        describe "applyEnvironment" $ do
            it "given a MICROHTTP_ override of an owned key, when applied, then it beats the file value" $ do
                let cfg = applyEnvironment "MICROHTTP_" serverEnvKeys [("MICROHTTP_PORT", "7200"), ("PATH", "/ignored")] (parsed "port = 7100")
                configInt "port" 0 cfg `shouldBe` Right 7200
            it "given a MICROHTTP_ override of an unowned key, when applied, then it is ignored" $ do
                let cfg = applyEnvironment "MICROHTTP_" serverEnvKeys [("MICROHTTP_DOCUMENT_TREE_ROOT", "/x")] (parsed "document_tree_root = /y")
                configString "document_tree_root" "" cfg `shouldBe` "/y"
        describe "configMounts" $ do
            it "given a comma-separated mount list, when parsed, then each prefix/root pair is returned" $
                configMounts "static_mounts" (parsed "static_mounts = /static/editor static/editor, /assets public/assets")
                    `shouldBe` [("/static/editor", "static/editor"), ("/assets", "public/assets")]
            it "given an absent mounts key, when parsed, then there are no mounts" $
                configMounts "static_mounts" (parsed "") `shouldBe` []
        describe "toSettings" $ do
            it "given known server keys, when mapping, then they override the defaults" $
                case toSettings (parsed "port = 9090\nmax_body_bytes = 2048\nhost = 127.0.0.1") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right settings -> do
                        settingsPort settings `shouldBe` Port 9090
                        settingsMaxBodyBytes settings `shouldBe` 2048
                        settingsHost settings `shouldBe` HostIPv4 127 0 0 1
            it "given a bad integer for a server key, when mapping, then it fails" $
                isLeft (toSettings (parsed "port = abc")) `shouldBe` True

parsed :: String -> Config
parsed text =
    case parseConfig text of
        Right cfg -> cfg
        Left err -> error ("test config failed to parse: " ++ show err)

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
