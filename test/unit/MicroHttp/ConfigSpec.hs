module MicroHttp.ConfigSpec (spec) where

import qualified MicroHttp.Config as Config
import qualified MicroHttp.Network.Socket as Socket (Host (..), Port (..))
import qualified MicroHttp.Server as Server (Settings (..))
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Config" $ do
        describe "parseConfig" $ do
            it "given keys, comments, blanks, and whitespace, when parsing, then values are read trimmed" $ do
                let cfg = parsed "  port = 8080 \n# a comment\n\nhost=0.0.0.0\n"
                Config.configString "host" "x" cfg `shouldBe` "0.0.0.0"
                Config.configInt "port" 0 cfg `shouldBe` Right 8080
            it "given a non-blank line without an equals, when parsing, then it is an error" $
                isLeft (Config.parseConfig "port = 8080\noops no equals") `shouldBe` True
        describe "typed lookups" $ do
            it "given an absent key, when looking up, then the default is returned" $ do
                Config.configString "missing" "def" (parsed "") `shouldBe` "def"
                Config.configInt "missing" 42 (parsed "") `shouldBe` Right 42
                Config.configBool "missing" True (parsed "") `shouldBe` Right True
            it "given a non-numeric integer key, when looking up, then it is an error" $
                isLeft (Config.configInt "port" 0 (parsed "port = eighty")) `shouldBe` True
            it "given a boolean key, when looking up, then true and false parse and anything else errors" $ do
                Config.configBool "on" False (parsed "on = true") `shouldBe` Right True
                Config.configBool "on" True (parsed "on = false") `shouldBe` Right False
                isLeft (Config.configBool "on" False (parsed "on = yes")) `shouldBe` True
        describe "applyEnvironment" $ do
            it "given a MICROHTTP_ override of an owned key, when applied, then it beats the file value" $ do
                let cfg = Config.applyEnvironment "MICROHTTP_" Config.serverEnvKeys [("MICROHTTP_PORT", "7200"), ("PATH", "/ignored")] (parsed "port = 7100")
                Config.configInt "port" 0 cfg `shouldBe` Right 7200
            it "given a MICROHTTP_ override of an unowned key, when applied, then it is ignored" $ do
                let cfg = Config.applyEnvironment "MICROHTTP_" Config.serverEnvKeys [("MICROHTTP_DOCUMENT_TREE_ROOT", "/x")] (parsed "document_tree_root = /y")
                Config.configString "document_tree_root" "" cfg `shouldBe` "/y"
        describe "configMounts" $ do
            it "given a comma-separated mount list, when parsed, then each prefix/root pair is returned" $
                Config.configMounts "static_mounts" (parsed "static_mounts = /static/editor static/editor, /assets public/assets")
                    `shouldBe` [("/static/editor", "static/editor"), ("/assets", "public/assets")]
            it "given an absent mounts key, when parsed, then there are no mounts" $
                Config.configMounts "static_mounts" (parsed "") `shouldBe` []
        describe "toSettings" $ do
            it "given known server keys, when mapping, then they override the defaults" $
                case Config.toSettings (parsed "port = 9090\nmax_body_bytes = 2048\nhost = 127.0.0.1") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right settings -> do
                        Server.settingsPort settings `shouldBe` Socket.Port 9090
                        Server.settingsMaxBodyBytes settings `shouldBe` 2048
                        Server.settingsHost settings `shouldBe` Socket.HostIPv4 127 0 0 1
            it "given a bad integer for a server key, when mapping, then it fails" $
                isLeft (Config.toSettings (parsed "port = abc")) `shouldBe` True
            -- The default binds loopback only. Binding the wildcard by default hid a port
            -- clash: another process holding 127.0.0.1:PORT still let the wildcard bind
            -- succeed, so the server started, said so, and never saw a request, because a
            -- more specific bind wins for loopback traffic. Loopback fails loudly instead.
            it "given no host key, when mapping, then the default is loopback" $
                case Config.toSettings (parsed "port = 9090") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right settings -> Server.settingsHost settings `shouldBe` Socket.HostIPv4 127 0 0 1
            it "given host 0.0.0.0, when mapping, then the wildcard is still selectable" $
                case Config.toSettings (parsed "host = 0.0.0.0") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right settings -> Server.settingsHost settings `shouldBe` Socket.HostAny

parsed :: String -> Config.Config
parsed text =
    case Config.parseConfig text of
        Right cfg -> cfg
        Left err -> error ("test config failed to parse: " ++ show err)

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
