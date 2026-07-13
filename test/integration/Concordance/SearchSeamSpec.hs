{- | Integration coverage for the Concordance embedding and store seams
(RFC-0034 phases 3-4). These tests exercise the real C shim, so they skip
(passing, with a message) when the shim is the stub or the model files are
absent -- `make check` stays green without the optional search toolchain.
-}
module Concordance.SearchSeamSpec (spec) where

import qualified Concordance.Embedding as Embedding
import qualified Concordance.Store as Store
import qualified Concordance.WordPiece as WordPiece
import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Process as Process
import qualified System.Directory as Directory
import qualified System.IO.TimeMilli as TimeMilli
import Test.Hspec

-- | Where `make search-model` puts the model, per platform.
modelCandidates :: [FilePath]
modelCandidates =
    [ "vendor/search/darwin-arm64/model"
    , "vendor/search/darwin-x86_64/model"
    , "vendor/search/linux-x86_64/model"
    , "vendor/search/linux-aarch64/model"
    ]

-- | The model directory, when the real shim and model are both present.
searchSetup :: IO (Maybe FilePath)
searchSetup = do
    available <- Store.searchAvailable
    if not available
        then pure Nothing
        else do
            found <-
                Monad.filterM
                    (\d -> Directory.doesFileExist (d ++ "/model_quantized.onnx"))
                    modelCandidates
            pure (case found of dir : _ -> Just dir; [] -> Nothing)

profileFor :: FilePath -> Embedding.Profile
profileFor modelDir =
    Embedding.Profile
        { Embedding.profileModelPath = modelDir ++ "/model_quantized.onnx"
        , Embedding.profilePooling = 1 -- CLS, bge-small
        , Embedding.profileDims = 384
        , Embedding.profileMaxTokens = 384
        , Embedding.profileThreads = 4
        , Embedding.profileQueryPrefix = ""
        }

storeDir :: FilePath
storeDir = "build/search-seam-spec-store"

-- | The committed reference: token ids and the fp32 reference vector.
readEmbedReference :: IO ([Int], [Double])
readEmbedReference = do
    content <- readFile "test/integration/Concordance/fixtures/embed-reference.txt"
    case lines content of
        (idsLine : vecLine : _) ->
            pure (map read (words idsLine), map read (words vecLine))
        _ -> fail "malformed embed-reference.txt"

cosine :: [Double] -> [Double] -> Double
cosine a b = sum (zipWith (*) a b)

skip :: String -> IO ()
skip reason = putStrLn ("      [skipped: " ++ reason ++ "]")

spec :: Spec
spec =
    describe "Concordance search seams (real shim)" $ do
        it "embeds the reference tokens close to the fp32 reference vector" $ do
            setup <- searchSetup
            case setup of
                Nothing -> skip "search shim or model not built"
                Just modelDir -> do
                    let profile = profileFor modelDir
                    opened <- Embedding.openEmbedder profile
                    case opened of
                        Left e -> fail ("openEmbedder: " ++ e)
                        Right embedder -> do
                            (ids, reference) <- readEmbedReference
                            got <- Embedding.embedTokens embedder ids
                            case got of
                                Left e -> fail ("embed: " ++ e)
                                Right vec -> do
                                    -- quantised model vs fp32 reference
                                    (cosine vec reference > 0.98) `shouldBe` True
                            Embedding.closeEmbedder

        it "lists every page when the listing outgrows one result buffer" $ do
            available <- Store.searchAvailable
            if not available
                then skip "search shim not built"
                else do
                    let dir = "build/search-pages-spec-store"
                    _ <- Process.runProcess "rm" ["-rf", dir] Nothing Nothing
                    Right store <- Store.openStore dir 4
                    -- Long page ids and many chunk rows per page push the
                    -- packed listing well past the 1 MiB result buffer.
                    let pageId i = "pages/" ++ replicate 500 'x' ++ "-" ++ show (i :: Int)
                        chunk = Store.StoreChunk "" "t" [1, 0, 0, 0]
                        nPages = 30
                    Monad.forM_ [1 .. nPages] $ \i -> do
                        Right () <-
                            Store.upsertPage
                                store
                                (pageId i)
                                ("stat-" ++ show i)
                                ("content-" ++ show i)
                                (replicate 100 chunk)
                        pure ()
                    listed <- Store.listPages store
                    case listed of
                        Left e -> fail ("listPages: " ++ e)
                        Right pages -> length pages `shouldBe` nPages
                    Store.closeStore
                    Monad.void (Process.runProcess "rm" ["-rf", dir] Nothing Nothing)

        it "given a store optimise in flight, when other green threads run, then they are not blocked (ADR-080)" $ do
            available <- Store.searchAvailable
            if not available
                then skip "search shim not built"
                else do
                    let dir = "build/search-async-spec-store"
                        dims = 8
                    _ <- Process.runProcess "rm" ["-rf", dir] Nothing Nothing
                    Right store <- Store.openStore dir dims
                    -- Many tiny upserts: version-history growth is per CALL,
                    -- and optimise's cleanup pass walks every accumulated
                    -- version -- the production stall (a page publish behind
                    -- seconds of cleanup). Tiny payloads keep marshalling and
                    -- GC noise out of the gap measurement below.
                    let chunk = Store.StoreChunk "a" "tiny chunk" (replicate dims 0.5)
                    Monad.forM_ [1 .. 450] $ \i -> do
                        Right () <- Store.upsertPage store ("async/tiny-" ++ show (i :: Int) ++ ".md") "s" "c" [chunk]
                        pure ()
                    done <- MVar.newEmptyMVar
                    started <- TimeMilli.getTimeMilli
                    _ <- Concurrent.forkIO $ do
                        Right () <- Store.optimizeStore store
                        MVar.putMVar done ()
                    -- Tick while the optimise runs, recording the longest gap
                    -- between ticks: a blocking FFI call shows up as one gap
                    -- the length of the whole call.
                    lastTick <- TimeMilli.getTimeMilli >>= IORef.newIORef
                    maxGap <- IORef.newIORef (0 :: Int)
                    let loop = do
                            finished <- MVar.tryTakeMVar done
                            now <- TimeMilli.getTimeMilli
                            previous <- IORef.readIORef lastTick
                            IORef.modifyIORef' maxGap (max (now - previous))
                            IORef.writeIORef lastTick now
                            case finished of
                                Just () -> pure ()
                                Nothing -> Concurrent.threadDelay 1000 >> loop
                    loop
                    finished <- TimeMilli.getTimeMilli
                    gap <- IORef.readIORef maxGap
                    let duration = finished - started
                    putStrLn ("      [optimise " ++ show duration ++ "ms, longest tick gap " ++ show gap ++ "ms]")
                    -- Guard: the optimise must be long enough to prove anything.
                    (duration >= 100) `shouldBe` True
                    -- The point: no stall the length of the optimise C call.
                    (gap <= 50) `shouldBe` True
                    Store.closeStore
                    Monad.void (Process.runProcess "rm" ["-rf", dir] Nothing Nothing)

        it "round-trips upsert, hybrid search, re-upsert, and delete" $ do
            setup <- searchSetup
            case setup of
                Nothing -> skip "search shim or model not built"
                Just modelDir -> do
                    _ <- Process.runProcess "rm" ["-rf", storeDir] Nothing Nothing
                    let profile = profileFor modelDir
                    vocabBytes <- BS.readFile (modelDir ++ "/vocab.txt")
                    let vocab = WordPiece.mkVocab vocabBytes
                    Right embedder <- Embedding.openEmbedder profile
                    Right store <- Store.openStore storeDir 384
                    let embedOrDie text = do
                            r <- Embedding.embedText embedder vocab profile text
                            either (fail . ("embed: " ++)) pure r
                        chunkFor anchor text = do
                            vec <- embedOrDie text
                            pure (Store.StoreChunk anchor text vec)

                    -- upsert two pages
                    aChunks <-
                        mapM
                            (uncurry chunkFor)
                            [ ("Failover", "Guide\nHow to configure SmartWAN failover timeouts.")
                            , ("Battery", "Guide\nReplacing the shelf label battery safely.")
                            ]
                    bChunks <-
                        mapM
                            (uncurry chunkFor)
                            [("", "Notes\nUnrelated notes about lunch menus and stationery.")]
                    Right () <- Store.upsertPage store "guides/a.md" "stat-a" "content-a" aChunks
                    Right () <- Store.upsertPage store "notes/b.md" "stat-b" "content-b" bChunks

                    -- hybrid search finds the failover chunk first
                    qv <- embedOrDie "smartwan failover configuration"
                    Right hits <- Store.searchStore store qv "failover" 4
                    case hits of
                        (top : _) -> do
                            Store.hitPage top `shouldBe` "guides/a.md"
                            Store.hitAnchor top `shouldBe` "Failover"
                        [] -> fail "no hits"

                    -- listing carries both pages' fingerprints
                    Right pages <- Store.listPages store
                    let fps = [(p, c) | Store.PageFingerprints p _ c <- pages]
                    (("guides/a.md", "content-a") `elem` fps) `shouldBe` True
                    (("notes/b.md", "content-b") `elem` fps) `shouldBe` True

                    -- re-upsert with fewer chunks replaces, not accumulates
                    aChunks2 <- mapM (uncurry chunkFor) [("Failover", "Guide\nRevised failover notes.")]
                    Right () <- Store.upsertPage store "guides/a.md" "stat-a2" "content-a2" aChunks2
                    Right hits2 <- Store.searchStore store qv "battery" 8
                    length [h | h <- hits2, Store.hitPage h == "guides/a.md"] `shouldBe` 1

                    -- optimisation compacts the upsert fragments; search still answers
                    Right () <- Store.optimizeStore store
                    Right hitsOpt <- Store.searchStore store qv "failover" 4
                    case hitsOpt of
                        (top : _) -> Store.hitPage top `shouldBe` "guides/a.md"
                        [] -> fail "no hits after optimise"

                    -- delete removes the page entirely
                    Right () <- Store.deletePage store "guides/a.md"
                    Right hits3 <- Store.searchStore store qv "failover" 8
                    [h | h <- hits3, Store.hitPage h == "guides/a.md"] `shouldBe` []

                    Store.closeStore
                    Embedding.closeEmbedder
                    Monad.void (Process.runProcess "rm" ["-rf", storeDir] Nothing Nothing)
