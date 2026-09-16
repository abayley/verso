module Verso.TreePathSpec (spec) where

import Test.Hspec
import qualified Verso.TreePath as TreePath

-- | Parses a path the spec knows to be valid; fails the test loudly otherwise.
path :: String -> TreePath.TreePath
path raw = case TreePath.parse raw of
    Just p -> p
    Nothing -> error ("TreePathSpec: fixture path does not parse: " ++ raw)

spec :: Spec
spec =
    describe "Verso.TreePath" $ do
        describe "parse and render" $ do
            it "given a nested page path, when parsed, then its segments are kept in order" $
                fmap TreePath.segments (TreePath.parse "tenants/anzco/overview.md") `shouldBe` Just ["tenants", "anzco", "overview.md"]
            it "given a path with doubled and edge slashes, when parsed and rendered, then it is canonical" $
                fmap TreePath.render (TreePath.parse "/a//b/") `shouldBe` Just "a/b"
            it "given the empty string, when parsed, then it is the root" $
                TreePath.parse "" `shouldBe` Just TreePath.root
            it "given the root, when rendered, then it is empty" $
                TreePath.render TreePath.root `shouldBe` ""
            it "given a parent-directory segment, when parsed, then it is refused" $
                TreePath.parse "a/../b.md" `shouldBe` Nothing
            it "given a dot segment, when parsed, then it is refused" $
                TreePath.parse "./a.md" `shouldBe` Nothing
            it "given a backslash in a segment, when parsed, then it is refused" $
                TreePath.parse "a\\b.md" `shouldBe` Nothing
            it "given a NUL in a segment, when parsed, then it is refused" $
                TreePath.parse "a\NULb.md" `shouldBe` Nothing
        describe "kind" $ do
            it "given a path ending in .md, when classified, then it is a page" $
                TreePath.kind (path "a/b.md") `shouldBe` TreePath.Page
            it "given a path not ending in .md, when classified, then it is a section" $
                TreePath.kind (path "a/b") `shouldBe` TreePath.Section
            it "given the root, when classified, then it is a section" $
                TreePath.kind TreePath.root `shouldBe` TreePath.Section
        describe "parent, name and slug" $ do
            it "given a nested page, when its parent is taken, then it is the enclosing section" $
                TreePath.parent (path "a/b/c.md") `shouldBe` path "a/b"
            it "given a top-level section, when its parent is taken, then it is the root" $
                TreePath.parent (path "a") `shouldBe` TreePath.root
            it "given the root, when its parent is taken, then it is the root" $
                TreePath.parent TreePath.root `shouldBe` TreePath.root
            it "given a page, when its name is taken, then it is the file name" $
                TreePath.name (path "a/b.md") `shouldBe` "b.md"
            it "given a page, when its slug is taken, then the .md is dropped" $
                TreePath.slug (path "a/b.md") `shouldBe` "b"
            it "given a section, when its slug is taken, then it is the last segment" $
                TreePath.slug (path "a/sec") `shouldBe` "sec"
            it "given the root, when its slug is taken, then it is empty" $
                TreePath.slug TreePath.root `shouldBe` ""
        describe "child" $ do
            it "given the root and a safe name, when a child is made, then it is that top-level path" $
                TreePath.child TreePath.root "a" `shouldBe` Just (path "a")
            it "given a section and a page name, when a child is made, then the page sits under it" $
                TreePath.child (path "a") "b.md" `shouldBe` Just (path "a/b.md")
            it "given a name containing a slash, when a child is made, then it is refused" $
                TreePath.child (path "a") "b/c" `shouldBe` Nothing
            it "given an empty name, when a child is made, then it is refused" $
                TreePath.child (path "a") "" `shouldBe` Nothing
        describe "layout" $ do
            it "given the root, when its section index is taken, then it is index.md" $
                TreePath.render (TreePath.sectionIndex TreePath.root) `shouldBe` "index.md"
            it "given a section, when its section index is taken, then it is its index.md" $
                TreePath.render (TreePath.sectionIndex (path "a/b")) `shouldBe` "a/b/index.md"
            it "given a nested page, when its meta directory is derived, then it sits beside the page" $
                TreePath.render (TreePath.metaDirectory (path "tenants/anzco/overview.md")) `shouldBe` "tenants/anzco/meta/overview.meta"
            it "given a root-level index page, when its meta directory is derived, then it is meta/index.meta" $
                TreePath.render (TreePath.metaDirectory (path "index.md")) `shouldBe` "meta/index.meta"
            it "given a page, when its peer assets folder is derived, then it is the sibling assets folder" $
                TreePath.render (TreePath.peerAssets (path "a/b.md")) `shouldBe` "a/assets"
            it "given a root-level page, when its peer assets folder is derived, then it is assets" $
                TreePath.render (TreePath.peerAssets (path "b.md")) `shouldBe` "assets"
        describe "resolve" $ do
            it "given a page, when resolved under a root, then the served path joins them" $
                TreePath.resolve "root" (path "a/b.md") `shouldBe` "root/a/b.md"
            it "given the root path, when resolved under a root, then it is the root directory" $
                TreePath.resolve "root" TreePath.root `shouldBe` "root"
        describe "trash entry ids" $ do
            it "given an all-digit id, when parsed, then it renders back unchanged" $
                fmap TreePath.renderTrashId (TreePath.parseTrashId "7") `shouldBe` Just "7"
            it "given an empty id, when parsed, then it is refused" $
                TreePath.parseTrashId "" `shouldBe` Nothing
            it "given a path-like id, when parsed, then it is refused" $
                TreePath.parseTrashId "../x" `shouldBe` Nothing
            it "given an id with letters, when parsed, then it is refused" $
                TreePath.parseTrashId "7a" `shouldBe` Nothing
            it "given a trash id, when its entry directory is derived, then it sits under the trash root" $
                fmap (TreePath.trashEntryDir "trash") (TreePath.parseTrashId "42") `shouldBe` Just "trash/42"
