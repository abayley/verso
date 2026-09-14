module MicroHttp.ProcessSpec (spec) where

import qualified Control.Exception as Exception
import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Process as Process
import qualified MicroHttp.Stream as Stream
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
        describe "withCapture" $ do
            it "given a program that writes lines, when its capture is folded line by line, then the lines are the result and both capture files are removed afterwards (RFC-0043)" $ do
                (folded, cap) <- Process.withCapture "printf" ["one\\ntwo\\nthree\\n"] Nothing Nothing $ \cap -> do
                    folded <- Stream.foldFileLines (\acc line -> pure (line : acc)) [] (Process.captureOut cap)
                    pure (folded, cap)
                fmap reverse folded `shouldBe` Right (map BS.pack ["one", "two", "three"])
                Process.captureExit cap `shouldBe` Exit.ExitSuccess
                Directory.doesFileExist (Process.captureOut cap) `shouldReturn` False
                Directory.doesFileExist (Process.captureErr cap) `shouldReturn` False

            it "given a consumer that throws, when run under withCapture, then the capture files are removed and the exception propagates (RFC-0043)" $ do
                holder <- Process.runProcessCaptured "echo" ["probe"] Nothing Nothing
                Process.removeCapture holder
                outcome <- Exception.try (Process.withCapture "echo" ["hello"] Nothing Nothing (\cap -> Exception.throwIO (userError ("consumer failed: " ++ Process.captureOut cap)) :: IO ()))
                path <- case outcome of
                    Left e -> pure (drop (length "user error (consumer failed: ") (takeWhile (/= ')') (show (e :: Exception.SomeException))))
                    Right () -> fail "the consumer's exception did not propagate"
                Directory.doesFileExist path `shouldReturn` False

        describe "runProcess" $ do
            it "given a program on PATH, when it is run, then its stdout and a success exit are captured" $ do
                res <- Process.runProcess "echo" ["hello"] Nothing Nothing
                Process.procExit res `shouldBe` Exit.ExitSuccess
                Process.procOut res `shouldBe` BS.pack "hello\n"
                Process.procErr res `shouldBe` BS.empty

            it "given a program that fails, when it is run, then its non-zero exit code is reported" $ do
                res <- Process.runProcess "false" [] Nothing Nothing
                Process.procExit res `shouldBe` Exit.ExitFailure 1

            it "given an executable that does not exist, when it is run, then exit 127 is reported" $ do
                res <- Process.runProcess "micro-http-no-such-program" [] Nothing Nothing
                Process.procExit res `shouldBe` Exit.ExitFailure 127

            it "given a program that writes to stderr and fails, when it is run, then stderr is captured separately" $ do
                res <- Process.runProcess "ls" ["/no/such/path/here"] Nothing Nothing
                (Process.procExit res == Exit.ExitSuccess) `shouldBe` False
                BS.null (Process.procErr res) `shouldBe` False
                Process.procOut res `shouldBe` BS.empty

            it "given an argument containing shell metacharacters, when the program is run, then the argument arrives verbatim and nothing is interpreted" $ do
                let nasty = "$(touch /tmp/micro-http-pwned); a b 'c'"
                res <- Process.runProcess "echo" [nasty] Nothing Nothing
                Process.procExit res `shouldBe` Exit.ExitSuccess
                -- the literal argument comes back unchanged: the shell never saw it
                Process.procOut res `shouldBe` BS.pack (nasty ++ "\n")

            it "given input bytes, when a program is run, then they are fed to its stdin" $ do
                res <- Process.runProcess "cat" [] Nothing (Just (BS.pack "piped input"))
                Process.procExit res `shouldBe` Exit.ExitSuccess
                Process.procOut res `shouldBe` BS.pack "piped input"

            it "given a working directory, when a program is run, then it starts there" $ do
                freshDir
                BS.writeFile (ioDir ++ "/marker.txt") (BS.pack "in-cwd")
                -- a relative path only resolves if the child chdir'd into ioDir
                res <- Process.runProcess "cat" ["marker.txt"] (Just ioDir) Nothing
                Process.procExit res `shouldBe` Exit.ExitSuccess
                Process.procOut res `shouldBe` BS.pack "in-cwd"

        describe "runProcessCaptured" $ do
            it "given a program, when captured, then stdout is left in a file the caller reads and removes" $ do
                cap <- Process.runProcessCaptured "echo" ["captured"] Nothing Nothing
                Process.captureExit cap `shouldBe` Exit.ExitSuccess
                out <- BS.readFile (Process.captureOut cap)
                out `shouldBe` BS.pack "captured\n"
                err <- BS.readFile (Process.captureErr cap)
                err `shouldBe` BS.empty
                Process.removeCapture cap
                Directory.doesFileExist (Process.captureOut cap) `shouldReturn` False
                Directory.doesFileExist (Process.captureErr cap) `shouldReturn` False

            it "given input bytes, when captured, then they are fed to stdin and the output capture holds them" $ do
                cap <- Process.runProcessCaptured "cat" [] Nothing (Just (BS.pack "piped capture"))
                Process.captureExit cap `shouldBe` Exit.ExitSuccess
                out <- BS.readFile (Process.captureOut cap)
                out `shouldBe` BS.pack "piped capture"
                Process.removeCapture cap

            it "given an executable that does not exist, when captured, then exit 127 and the stderr capture names the failure" $ do
                cap <- Process.runProcessCaptured "micro-http-no-such-program" [] Nothing Nothing
                Process.captureExit cap `shouldBe` Exit.ExitFailure 127
                err <- BS.readFile (Process.captureErr cap)
                BS.null err `shouldBe` False
                Process.removeCapture cap
