module Verso.GitSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
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
        it "initialises a repository and is idempotent" $ do
            root <- freshDir
            first <- Git.ensureRepository root importer
            first `shouldBe` Git.Initialised
            hasGit <- Directory.doesDirectoryExist (root ++ "/.git")
            hasGit `shouldBe` True
            second <- Git.ensureRepository root importer
            second `shouldBe` Git.AlreadyPresent

        it "commits a page and reads it back from the log" $ do
            root <- freshRepo
            writeText (root ++ "/page.md") "# Hello"
            result <- Git.commitPaths root author "Add page" ["page.md"]
            isCommitted result `shouldBe` True
            revs <- Git.logForPath root "page.md"
            length revs `shouldBe` 1
            fmap Git.revAuthor (listToMaybe revs) `shouldBe` Just "Test Author"
            fmap Git.revSubject (listToMaybe revs) `shouldBe` Just "Add page"

        it "commits all tree changes in one revision (commitAll)" $ do
            root <- freshRepo
            writeText (root ++ "/x.md") "x body"
            writeText (root ++ "/y.md") "y body"
            result <- Git.commitAll root author "Publish batch"
            isCommitted result `shouldBe` True
            rx <- Git.logForPath root "x.md"
            ry <- Git.logForPath root "y.md"
            length rx `shouldBe` 1
            length ry `shouldBe` 1

        it "reports nothing to commit when there is no change" $ do
            root <- freshRepo
            writeText (root ++ "/page.md") "# Hello"
            _ <- Git.commitPaths root author "Add page" ["page.md"]
            again <- Git.commitPaths root author "No change" ["page.md"]
            again `shouldBe` Git.NothingToCommit

        it "reads a page at a revision and diffs two revisions" $ do
            root <- freshRepo
            writeText (root ++ "/p.md") "alpha beta\n"
            c1 <- Git.commitPaths root author "v1" ["p.md"]
            writeText (root ++ "/p.md") "alpha gamma\n"
            c2 <- Git.commitPaths root author "v2" ["p.md"]
            atV1 <- Git.showFileAtRevision root (hashOf c1) "p.md"
            atV1 `shouldBe` BS.pack "alpha beta\n"
            diff <- Git.diffBetween root (hashOf c1) (hashOf c2) "p.md"
            (("beta" `isIn` diff) && ("gamma" `isIn` diff)) `shouldBe` True

        it "follows a page's history across a rename" $ do
            root <- freshRepo
            writeText (root ++ "/a.md") "stable content"
            _ <- Git.commitPaths root author "Add a" ["a.md"]
            _ <- FileSystem.renamePath (root ++ "/a.md") (root ++ "/b.md")
            _ <- Git.commitPaths root author "Rename a to b" ["a.md", "b.md"]
            revs <- Git.logForPath root "b.md"
            length revs `shouldBe` 2
  where
    listToMaybe [] = Nothing
    listToMaybe (x : _) = Just x
    hashOf (Git.Committed h) = h
    hashOf _ = ""
    isIn needle haystack = BS.isInfixOf (BS.pack needle) (BS.pack haystack)
