module MicroHttp.ConfigSpec (spec) where

import qualified Control.Monad as Monad
import qualified MicroHttp.Config as Config
import qualified MicroHttp.Network.Socket as Socket
import qualified MicroHttp.Server as Server
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
