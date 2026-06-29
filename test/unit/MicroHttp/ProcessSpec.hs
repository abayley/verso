module MicroHttp.ProcessSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
import qualified System.Exit as Exit
import Test.Hspec

-- | A scratch directory under build/ for the working-directory test.
ioDir :: FilePath
ioDir = "build/process-spec"

freshDir :: IO ()
freshDir = do
    exists <- Directory.doesDirectoryExist ioDir
    if exists
        then do
            names <- Directory.listDirectory ioDir
            mapM_ (\n -> Directory.removeFile (ioDir ++ "/" ++ n)) names
        else Directory.createDirectoryIfMissing True ioDir

spec :: Spec
spec =
    describe "MicroHttp.Process" $ do
        describe "runProcess" $ do
            it "captures stdout and a success exit (resolving the executable via PATH)" $ do
                res <- Process.runProcess "echo" ["hello"] Nothing Nothing
                Process.procExit res `shouldBe` Exit.ExitSuccess
                Process.procOut res `shouldBe` BS.pack "hello\n"
                Process.procErr res `shouldBe` BS.empty

            it "reports a non-zero exit code" $ do
                res <- Process.runProcess "false" [] Nothing Nothing
                Process.procExit res `shouldBe` Exit.ExitFailure 1

            it "captures stderr separately on failure" $ do
                res <- Process.runProcess "ls" ["/no/such/path/here"] Nothing Nothing
                (Process.procExit res == Exit.ExitSuccess) `shouldBe` False
                BS.null (Process.procErr res) `shouldBe` False
                Process.procOut res `shouldBe` BS.empty

            it "passes arguments verbatim, with no shell interpretation" $ do
                let nasty = "$(touch /tmp/micro-http-pwned); a b 'c'"
                res <- Process.runProcess "echo" [nasty] Nothing Nothing
                Process.procExit res `shouldBe` Exit.ExitSuccess
                -- the literal argument comes back unchanged: the shell never saw it
                Process.procOut res `shouldBe` BS.pack (nasty ++ "\n")

            it "feeds supplied bytes to the child's stdin" $ do
                res <- Process.runProcess "cat" [] Nothing (Just (BS.pack "piped input"))
                Process.procExit res `shouldBe` Exit.ExitSuccess
                Process.procOut res `shouldBe` BS.pack "piped input"

            it "runs the child in the requested working directory" $ do
                freshDir
                BS.writeFile (ioDir ++ "/marker.txt") (BS.pack "in-cwd")
                -- a relative path only resolves if the child chdir'd into ioDir
                res <- Process.runProcess "cat" ["marker.txt"] (Just ioDir) Nothing
                Process.procExit res `shouldBe` Exit.ExitSuccess
                Process.procOut res `shouldBe` BS.pack "in-cwd"
