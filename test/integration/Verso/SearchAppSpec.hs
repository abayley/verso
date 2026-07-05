{- | End-to-end coverage of Verso search (RFC-0034 phases 6-7): the queue
worker, reconcile cascade, and the @/search@ endpoint, driven through the
real tree routes with a live search runtime. Skips (passing, with a
message) when the shim or model is absent.
-}
module Verso.SearchAppSpec (spec) where

import qualified Concordance.Embedding as Embedding
import qualified Concordance.Store as Store
import qualified Control.Concurrent as Concurrent
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified MicroHttp.FileSystem as FileSystem
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee
import qualified MicroHttp.Process as Process
import qualified MicroHttp.Router as Router
import qualified System.Directory as Directory
import Test.Hspec
import qualified Verso.App as App
import qualified Verso.SearchIndex as SearchIndex

root :: FilePath
root = "build/search-app-spec/tree"

indexDir :: FilePath
indexDir = "build/search-app-spec/index"

modelCandidates :: [FilePath]
modelCandidates =
    [ "vendor/search/darwin-arm64/model"
    , "vendor/search/darwin-x86_64/model"
    , "vendor/search/linux-x86_64/model"
    , "vendor/search/linux-aarch64/model"
    ]

-- | A live runtime over a fresh scratch tree, or Nothing to skip.
setup :: IO (Maybe SearchIndex.SearchRuntime)
setup = do
    available <- Store.searchAvailable
    found <-
        Monad.filterM
            (\d -> Directory.doesFileExist (d ++ "/model_quantized.onnx"))
            modelCandidates
    case (available, found) of
        (True, modelDir : _) -> do
            _ <- Process.runProcess "rm" ["-rf", "build/search-app-spec"] Nothing Nothing
            Directory.createDirectoryIfMissing True root
            writeFile (root ++ "/index.md") "---\nname: Home\n---\nWelcome home.\n"
            writeFile
                (root ++ "/failover.md")
                "---\nname: Failover Guide\n---\n# Failover\nConfiguring SmartWAN failover timeouts.\n"
            SearchIndex.startSearch
                SearchIndex.SearchConfig
                    { SearchIndex.searchRoot = root
                    , SearchIndex.searchIndexDir = indexDir
                    , SearchIndex.searchModelId = "spec-model"
                    , SearchIndex.searchProfile =
                        Embedding.Profile
                            { Embedding.profileModelPath = modelDir ++ "/model_quantized.onnx"
                            , Embedding.profilePooling = 1
                            , Embedding.profileDims = 384
                            , Embedding.profileMaxTokens = 384
                            , Embedding.profileThreads = 4
                            , Embedding.profileQueryPrefix = ""
                            }
                    , SearchIndex.searchVocabPath = modelDir ++ "/vocab.txt"
                    , SearchIndex.searchTitleOf = const
                    , SearchIndex.searchLog = \_ -> pure ()
                    }
        _ -> pure Nothing

-- | Polls until the queue is idle (the worker drained), within a bound.
awaitDrain :: SearchIndex.SearchRuntime -> IO ()
awaitDrain runtime = go (600 :: Int)
  where
    go 0 = fail "search queue did not drain"
    go n = do
        depth <- SearchIndex.searchDepth runtime
        Monad.unless (depth == 0) $ do
            Concurrent.threadDelay 100000
            go (n - 1)

-- | Runs one request through the tree routes with the live runtime.
runRoute :: SearchIndex.SearchRuntime -> Http.RequestHead -> String -> IO Http.Response
runRoute runtime reqHead body = do
    let routes =
            App.treeRoutes
                Nothing
                Nothing
                (Just runtime)
                App.noVersioning
                "paper"
                root
                "build/search-app-spec/oplog"
                "build/search-app-spec/trash"
                "build/search-app-spec/linkindex"
    outcome <-
        Iteratee.strictEnumerator (BS.pack body) (Router.route routes reqHead)
            >>= Iteratee.run
    case outcome of
        Right response -> pure response
        Left err -> fail ("route failed: " ++ show err)

request :: Http.Method -> [String] -> [(String, String)] -> Http.RequestHead
request method path query =
    Http.emptyRequestHead
        { Http.requestMethod = method
        , Http.requestPath = path
        , Http.requestQuery = query
        }

bodyText :: Http.Response -> String
bodyText response =
    case Http.responseBody response of
        Http.StrictBody body -> BS.unpack body
        _ -> "<stream>"

status :: Http.Response -> Int
status = Http.statusCode . Http.responseStatus

skip :: String -> IO ()
skip reason = putStrLn ("      [skipped: " ++ reason ++ "]")

spec :: Spec
spec =
    describe "Verso search end to end (RFC-0034)" $
        it "indexes at startup, on save, and across reconcile; /search answers" $ do
            ready <- setup
            case ready of
                Nothing -> skip "search shim or model not built"
                Just runtime -> do
                    -- startup reconcile indexes the seeded tree
                    awaitDrain runtime
                    Right hits <- SearchIndex.searchQuery runtime "smartwan failover" 5
                    map Store.hitPage hits `shouldSatisfyFirst` "failover.md"

                    -- a save through the real handler becomes searchable
                    saveResp <-
                        runRoute
                            runtime
                            (request Http.POST ["documents", "quokka.md"] [])
                            "markdown=%23%20Quokkas%0AQuokka%20battery%20replacement%20guide."
                    status saveResp `shouldBe` 303
                    awaitDrain runtime
                    Right hits2 <- SearchIndex.searchQuery runtime "quokka battery" 5
                    map Store.hitPage hits2 `shouldSatisfyFirst` "quokka.md"

                    -- an out-of-band move + reconcile: old path gone, new one live
                    Monad.void (FileSystem.renamePath (root ++ "/quokka.md") (root ++ "/moved-quokka.md"))
                    SearchIndex.enqueueReconcile runtime
                    awaitDrain runtime
                    Right hits3 <- SearchIndex.searchQuery runtime "quokka battery" 5
                    map Store.hitPage hits3 `shouldSatisfyFirst` "moved-quokka.md"
                    ("quokka.md" `elem` map Store.hitPage hits3) `shouldBe` False

                    -- the endpoint renders results and the disabled message
                    okResp <- runRoute runtime (request Http.GET ["search"] [("q", "failover")]) ""
                    status okResp `shouldBe` 200
                    ("failover.md" `List.isInfixOf` bodyText okResp) `shouldBe` True

                    -- and the json flavour carries titles and excerpts for the search box
                    jsonResp <- runRoute runtime (request Http.GET ["search"] [("q", "failover"), ("json", "")]) ""
                    status jsonResp `shouldBe` 200
                    ("\"enabled\":true" `List.isInfixOf` bodyText jsonResp) `shouldBe` True
                    ("\"path\":\"failover.md\"" `List.isInfixOf` bodyText jsonResp) `shouldBe` True
                    ("\"title\":" `List.isInfixOf` bodyText jsonResp) `shouldBe` True
                    Monad.void (Process.runProcess "rm" ["-rf", "build/search-app-spec"] Nothing Nothing)

-- | Asserts the first element matches (with a helpful failure).
shouldSatisfyFirst :: [String] -> String -> IO ()
shouldSatisfyFirst xs expected =
    case xs of
        (x : _) -> x `shouldBe` expected
        [] -> fail ("no results; expected first " ++ expected)
