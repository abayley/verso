module MicroHttp.ConfigSpec (spec) where

import Control.Monad (when)
import MicroHttp.Config (Config, ConfigError, loadConfig, toSettings)
import MicroHttp.Network.Socket (Port (..))
import MicroHttp.Server (Settings (..), defaultSettings)
import System.Directory (doesFileExist, removeFile)
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Config loading" $ do
        it "given a config file, when loaded, then the settings reflect its values" $ do
            writeFile configFile "port = 7100\nmax_body_bytes = 4096\n"
            loaded <- loadConfig configFile
            removeFile configFile
            settingsOf loaded $ \settings -> do
                settingsPort settings `shouldBe` Port 7100
                settingsMaxBodyBytes settings `shouldBe` 4096
        it "given no config file, when loaded, then the built-in defaults apply" $ do
            removeIfExists configFile
            loaded <- loadConfig configFile
            settingsOf loaded (\settings -> settingsPort settings `shouldBe` settingsPort defaultSettings)

settingsOf :: Either ConfigError Config -> (Settings -> Expectation) -> Expectation
settingsOf loaded check =
    case loaded >>= toSettings of
        Right settings -> check settings
        Left _ -> expect "config failed to load" False

configFile :: FilePath
configFile = "build/test-config.conf"

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    present <- doesFileExist path
    when present (removeFile path)
