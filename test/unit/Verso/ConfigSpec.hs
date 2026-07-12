module Verso.ConfigSpec (spec) where

import qualified Data.List as List
import qualified MicroHttp.Config as Config
import Test.Hspec
import qualified Verso.Config as VConfig

spec :: Spec
spec =
    describe "Verso.Config" $ do
        describe "fromConfig" $ do
            it "given application keys, when read, then the record holds their values" $
                case VConfig.fromConfig (parsed "document_tree_root = /docs\neditor_theme = studio\nlog_keep = 9") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> do
                        VConfig.documentTreeRoot vc `shouldBe` "/docs"
                        VConfig.editorTheme vc `shouldBe` "studio"
                        VConfig.logKeep vc `shouldBe` 9
            it "given a config with only the tree root, when read, then the documented defaults apply" $
                case VConfig.fromConfig (parsed "document_tree_root = /docs") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> do
                        VConfig.documentTreeRoot vc `shouldBe` "/docs"
                        VConfig.editorTheme vc `shouldBe` "shadcn"
                        VConfig.trashRoot vc `shouldBe` "data/trash"
                        VConfig.logMaxBytes vc `shouldBe` 10485760
                        VConfig.logKeep vc `shouldBe` 5
                        VConfig.versioningEnabled vc `shouldBe` True
                        VConfig.linkIndexEnabled vc `shouldBe` True
            it "given no document_tree_root, when read, then it fails naming the missing key" $
                case VConfig.fromConfig (parsed "editor_theme = studio") of
                    Left (Config.ConfigError message) -> ("document_tree_root" `List.isInfixOf` message) `shouldBe` True
                    Right _ -> expect "config without document_tree_root was accepted" False
            it "given link_index_enabled = false, when read, then the index is disabled" $
                case VConfig.fromConfig (parsed "document_tree_root = /docs\nlink_index_enabled = false") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> VConfig.linkIndexEnabled vc `shouldBe` False
            it "given a malformed integer key, when read, then it fails" $
                isLeft (VConfig.fromConfig (parsed "log_max_bytes = lots")) `shouldBe` True
        describe "VERSO_ overlay" $ do
            it "given a VERSO_ override of an owned key, when applied, then it beats the file value" $
                case VConfig.fromConfig (Config.applyEnvironment "VERSO_" VConfig.appEnvKeys [("VERSO_EDITOR_THEME", "studio")] (parsed "document_tree_root = /docs\neditor_theme = paper")) of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> VConfig.editorTheme vc `shouldBe` "studio"
            it "given a VERSO_ override of a server key, when applied, then it does not leak into that key" $ do
                let cfg = Config.applyEnvironment "VERSO_" VConfig.appEnvKeys [("VERSO_PORT", "9999")] (parsed "port = 8080")
                Config.configInt "port" 0 cfg `shouldBe` Right 8080

parsed :: String -> Config.Config
parsed text =
    case Config.parseConfig text of
        Right cfg -> cfg
        Left err -> error ("test config failed to parse: " ++ show err)

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
