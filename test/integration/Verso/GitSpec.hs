module Verso.GitSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
import qualified System.Exit as Exit
import Test.Hspec
import qualified Verso.Git as Git

-- | A scratch repository directory under build/, recreated per example.
ioDir :: FilePath
ioDir = "build/git-spec"

importer :: Git.Identity
importer = Git.Identity "Verso" "verso@verso.local"

author :: Git.Identity
author = Git.Identity "Test Author" "test@example.com"

-- | Wipes (rm -rf, since .git nests) and recreates the scratch directory; not yet a repository.
freshDir :: IO FilePath
freshDir = do
    _ <- Process.runProcess "rm" ["-rf", ioDir] Nothing Nothing
    Directory.createDirectoryIfMissing True ioDir
    pure ioDir

-- | A fresh, initialised repository (empty tree, so no import commit yet).
freshRepo :: IO FilePath
freshRepo = do
    root <- freshDir
    _ <- Git.ensureRepository root importer
    pure root

writeText :: FilePath -> String -> IO ()
writeText path = BS.writeFile path . BS.pack

isCommitted :: Git.CommitResult -> Bool
isCommitted (Git.Committed _) = True
isCommitted _ = False

spec :: Spec
spec =
    describe "Verso.Git" $ do
        it "given a directory with no repository, when one is ensured twice, then it is initialised once and the second call is a no-op" $ do
            root <- freshDir
            first <- Git.ensureRepository root importer
            first `shouldBe` Git.Initialised
            hasGit <- Directory.doesDirectoryExist (root ++ "/.git")
            hasGit `shouldBe` True
            second <- Git.ensureRepository root importer
            second `shouldBe` Git.AlreadyPresent

        it "given a page, when it is committed, then it can be read back from the log" $ do
            root <- freshRepo
            writeText (root ++ "/page.md") "# Hello"
            result <- Git.commitPaths root author "Add page" ["page.md"]
            isCommitted result `shouldBe` True
            revs <- Git.logForPath root "page.md"
            length revs `shouldBe` 1
            fmap Git.revAuthor (listToMaybe revs) `shouldBe` Just "Test Author"
            fmap Git.revSubject (listToMaybe revs) `shouldBe` Just "Add page"

        it "given several changed pages, when the tree is committed, then all of them land in one revision" $ do
            root <- freshRepo
            writeText (root ++ "/x.md") "x body"
            writeText (root ++ "/y.md") "y body"
            result <- Git.commitAll root author "Publish batch"
            isCommitted result `shouldBe` True
            rx <- Git.logForPath root "x.md"
            ry <- Git.logForPath root "y.md"
            length rx `shouldBe` 1
            length ry `shouldBe` 1

        it "given no change, when a commit is attempted, then nothing to commit is reported" $ do
            root <- freshRepo
            writeText (root ++ "/page.md") "# Hello"
            _ <- Git.commitPaths root author "Add page" ["page.md"]
            again <- Git.commitPaths root author "No change" ["page.md"]
            again `shouldBe` Git.NothingToCommit

        it "given a revision, when captured to disk, then the stdout capture holds the exact bytes and is the caller's to remove (RFC-0040)" $ do
            root <- freshRepo
            writeText (root ++ "/p.md") "alpha beta\n"
            c1 <- Git.commitPaths root author "v1" ["p.md"]
            cap <- Git.showFileAtRevisionCaptured root (hashOf c1) "p.md"
            Process.captureExit cap `shouldBe` Exit.ExitSuccess
            captured <- BS.readFile (Process.captureOut cap)
            captured `shouldBe` BS.pack "alpha beta\n"
            Process.removeCapture cap
            Directory.doesFileExist (Process.captureOut cap) `shouldReturn` False

        it "given two revisions of a page, when their diff is captured to disk, then the stdout capture holds the unified diff and is the caller's to remove (RFC-0040)" $ do
            root <- freshRepo
            writeText (root ++ "/p.md") "alpha beta\n"
            c1 <- Git.commitPaths root author "v1" ["p.md"]
            writeText (root ++ "/p.md") "alpha gamma\n"
            c2 <- Git.commitPaths root author "v2" ["p.md"]
            cap <- Git.diffBetweenCaptured root (hashOf c1) (hashOf c2) "p.md"
            Process.captureExit cap `shouldBe` Exit.ExitSuccess
            captured <- BS.readFile (Process.captureOut cap)
            (BS.isInfixOf (BS.pack "-alpha beta") captured && BS.isInfixOf (BS.pack "+alpha gamma") captured) `shouldBe` True
            Process.removeCapture cap
            Directory.doesFileExist (Process.captureOut cap) `shouldReturn` False
            Directory.doesFileExist (Process.captureErr cap) `shouldReturn` False

        it "given a path absent at a revision, when captured, then git exits non-zero" $ do
            root <- freshRepo
            writeText (root ++ "/p.md") "only page\n"
            c1 <- Git.commitPaths root author "v1" ["p.md"]
            cap <- Git.showFileAtRevisionCaptured root (hashOf c1) "absent.md"
            (Process.captureExit cap == Exit.ExitSuccess) `shouldBe` False
            Process.removeCapture cap

        it "given a page that has been renamed, when its history is read, then it is followed across the rename" $ do
            root <- freshRepo
            writeText (root ++ "/a.md") "stable content"
            _ <- Git.commitPaths root author "Add a" ["a.md"]
            _ <- FileSystem.renamePath (root ++ "/a.md") (root ++ "/b.md")
            _ <- Git.commitPaths root author "Rename a to b" ["a.md", "b.md"]
            revs <- Git.logForPath root "b.md"
            length revs `shouldBe` 2
            map Git.revSubject revs `shouldBe` ["Rename a to b", "Add a"]
  where
    listToMaybe [] = Nothing
    listToMaybe (x : _) = Just x
    hashOf (Git.Committed h) = h
    hashOf _ = ""
