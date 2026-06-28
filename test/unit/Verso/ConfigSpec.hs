module Verso.ConfigSpec (spec) where

import MicroHttp.Config (Config, applyEnvironment, configInt, parseConfig)
import Test.Hspec
import Verso.Config (VersoConfig (..), appEnvKeys, fromConfig)

spec :: Spec
spec =
    describe "Verso.Config" $ do
        describe "fromConfig" $ do
            it "given application keys, when read, then the record holds their values" $
                case fromConfig (parsed "document_tree_root = /docs\neditor_theme = studio\nlog_keep = 9") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> do
                        documentTreeRoot vc `shouldBe` "/docs"
                        editorTheme vc `shouldBe` "studio"
                        logKeep vc `shouldBe` 9
            it "given an empty config, when read, then the documented defaults apply" $
                case fromConfig (parsed "") of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> do
                        documentTreeRoot vc `shouldBe` ""
                        documentRoot vc `shouldBe` "data/documents"
                        editorTheme vc `shouldBe` "paper"
                        trashRoot vc `shouldBe` "data/trash"
                        logMaxBytes vc `shouldBe` 10485760
                        logKeep vc `shouldBe` 5
            it "given a malformed integer key, when read, then it fails" $
                isLeft (fromConfig (parsed "log_max_bytes = lots")) `shouldBe` True
        describe "VERSO_ overlay" $ do
            it "given a VERSO_ override of an owned key, when applied, then it beats the file value" $
                case fromConfig (applyEnvironment "VERSO_" appEnvKeys [("VERSO_EDITOR_THEME", "studio")] (parsed "editor_theme = paper")) of
                    Left err -> expect ("unexpected config error: " ++ show err) False
                    Right vc -> editorTheme vc `shouldBe` "studio"
            it "given a VERSO_ override of a server key, when applied, then it does not leak into that key" $ do
                let cfg = applyEnvironment "VERSO_" appEnvKeys [("VERSO_PORT", "9999")] (parsed "port = 8080")
                configInt "port" 0 cfg `shouldBe` Right 8080

parsed :: String -> Config
parsed text =
    case parseConfig text of
        Right cfg -> cfg
        Left err -> error ("test config failed to parse: " ++ show err)

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
