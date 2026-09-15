module MicroHttp.ConfigSpec (spec) where

import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Config as Config
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Server as Server
import qualified MicroHttp.Utf8 as Utf8
import qualified System.Directory as Directory
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Config loading" $ do
        it "given a config file, when loaded, then the settings reflect its values" $ do
            writeFile configFile "port = 7100\nmax_body_bytes = 4096\n"
            loaded <- Config.loadConfigWith [("MICROHTTP_", Config.serverEnvKeys)] configFile
            Directory.removeFile configFile
            settingsOf loaded $ \settings -> do
                Server.settingsPort settings `shouldBe` Socket.Port 7100
                Server.settingsMaxBodyBytes settings `shouldBe` 4096
        it "given a value holding characters above Latin-1 in the file's UTF-8, when loaded, then the value is the decoded characters (RFC-0043)" $ do
            BS.writeFile configFile (Utf8.encodeText "document_tree_root = /srv/caf\233 \8212 \1046\n")
            loaded <- Config.loadConfigWith [] configFile
            Directory.removeFile configFile
            fmap (Config.configString "document_tree_root" "") loaded `shouldBe` Right "/srv/caf\233 \8212 \1046"
        it "given a malformed line, when loaded, then the error names the line" $ do
            writeFile configFile "port = 7100\nno equals here\n"
            loaded <- Config.loadConfigWith [] configFile
            Directory.removeFile configFile
            Monad.void loaded `shouldBe` Left (Config.ConfigError "malformed config line: no equals here")
        it "given no config file, when loaded, then the built-in defaults apply" $ do
            removeIfExists configFile
            loaded <- Config.loadConfigWith [("MICROHTTP_", Config.serverEnvKeys)] configFile
            settingsOf loaded (\settings -> Server.settingsPort settings `shouldBe` Server.settingsPort Server.defaultSettings)

settingsOf :: Either Config.ConfigError Config.Config -> (Server.Settings -> Expectation) -> Expectation
settingsOf loaded check =
    case loaded >>= Config.toSettings of
        Right settings -> check settings
        Left _ -> expect "config failed to load" False

configFile :: FilePath
configFile = "build/test-config.conf"

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    present <- Directory.doesFileExist path
    Monad.when present (Directory.removeFile path)
