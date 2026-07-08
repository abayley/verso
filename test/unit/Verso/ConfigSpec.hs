module Verso.ConfigSpec (spec) where

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
            it "given an empty config, when read, then the documented defaults apply" $
                case VConfig.fromConfig (parsed "") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> do
                        VConfig.documentTreeRoot vc `shouldBe` ""
                        VConfig.documentRoot vc `shouldBe` "data/documents"
                        VConfig.editorTheme vc `shouldBe` "shadcn"
                        VConfig.trashRoot vc `shouldBe` "data/trash"
                        VConfig.logMaxBytes vc `shouldBe` 10485760
                        VConfig.logKeep vc `shouldBe` 5
                        VConfig.versioningEnabled vc `shouldBe` True
                        VConfig.linkIndexEnabled vc `shouldBe` True
            it "given link_index_enabled = false, when read, then the index is disabled" $
                case VConfig.fromConfig (parsed "link_index_enabled = false") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> VConfig.linkIndexEnabled vc `shouldBe` False
            it "given a malformed integer key, when read, then it fails" $
                isLeft (VConfig.fromConfig (parsed "log_max_bytes = lots")) `shouldBe` True
        describe "VERSO_ overlay" $ do
            it "given a VERSO_ override of an owned key, when applied, then it beats the file value" $
                case VConfig.fromConfig (Config.applyEnvironment "VERSO_" VConfig.appEnvKeys [("VERSO_EDITOR_THEME", "studio")] (parsed "editor_theme = paper")) of
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
