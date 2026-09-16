module MicroHttp.StaticSpec (spec) where

import qualified MicroHttp.Static as Static
import Test.Hspec

spec :: Spec
spec =
    describe "MicroHttp.Static" $ do
        describe "resolveStaticPath" $ do
            it "given safe components, when resolving, then they join onto the root" $
                Static.resolveStaticPath "root" ["css", "app.css"] `shouldBe` Just "root/css/app.css"
            it "given no components, when resolving, then the root itself is returned" $
                Static.resolveStaticPath "root" [] `shouldBe` Just "root"
            it "given a parent-directory component, when resolving, then it is rejected" $
                Static.resolveStaticPath "root" ["..", "secret"] `shouldBe` Nothing
            it "given a dot component, when resolving, then it is rejected" $
                Static.resolveStaticPath "root" ["."] `shouldBe` Nothing
            it "given a component with an embedded slash, when resolving, then it is rejected" $
                Static.resolveStaticPath "root" ["a/b"] `shouldBe` Nothing
            it "given a component with a backslash, when resolving, then it is rejected" $
                Static.resolveStaticPath "root" ["a\\b"] `shouldBe` Nothing
            it "given a component with a NUL, when resolving, then it is rejected" $
                Static.resolveStaticPath "root" ["a\NULb"] `shouldBe` Nothing
        describe "safeComponent" $ do
            it "given a plain file name, when checked, then it is safe" $
                Static.safeComponent "overview.md" `shouldBe` True
            it "given an empty component, when checked, then it is unsafe" $
                Static.safeComponent "" `shouldBe` False
            it "given a parent-directory component, when checked, then it is unsafe" $
                Static.safeComponent ".." `shouldBe` False
            it "given a component with an embedded slash, when checked, then it is unsafe" $
                Static.safeComponent "a/b" `shouldBe` False
        describe "contentTypeFor" $ do
            it "given a css file, when choosing a type, then text/css is returned" $
                Static.contentTypeFor "app.css" `shouldBe` "text/css"
            it "given a js file, when choosing a type, then text/javascript is returned" $
                Static.contentTypeFor "editor.js" `shouldBe` "text/javascript"
            it "given an uppercase extension, when choosing a type, then it matches case-insensitively" $
                Static.contentTypeFor "LOGO.PNG" `shouldBe` "image/png"
            it "given a path with directories, when choosing a type, then the file extension is used" $
                Static.contentTypeFor "a/b/c.svg" `shouldBe` "image/svg+xml"
            it "given a webp image, when choosing a type, then image/webp is returned" $
                Static.contentTypeFor "photo.webp" `shouldBe` "image/webp"
            it "given a pdf file, when choosing a type, then application/pdf is returned" $
                Static.contentTypeFor "report.pdf" `shouldBe` "application/pdf"
            it "given a markdown file, when choosing a type, then text/markdown is returned" $
                Static.contentTypeFor "notes.md" `shouldBe` "text/markdown"
            it "given a csv file, when choosing a type, then text/csv is returned" $
                Static.contentTypeFor "data.csv" `shouldBe` "text/csv"
            it "given a zip file, when choosing a type, then application/zip is returned" $
                Static.contentTypeFor "bundle.zip" `shouldBe` "application/zip"
            it "given a file with no extension, when choosing a type, then the default is returned" $
                Static.contentTypeFor "README" `shouldBe` "application/octet-stream"
            it "given a dotted directory but a plain file, when choosing a type, then the default is returned" $
                Static.contentTypeFor "v1.2/name" `shouldBe` "application/octet-stream"
