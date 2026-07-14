{- | Text embedding for the Concordance search engine (RFC-0034): WordPiece
tokenisation (pure) feeding the ONNX Runtime embedding shim (FFI). The
'Embedder' is a record of functions so tests and the disabled-search path
can inject fakes; 'openEmbedder' builds the real one over the C shim.

Every FFI call here blocks the whole MicroHs runtime for its duration
(~2 ms for a query, ~30 ms for a full chunk with the default profile), so
callers doing bulk work must yield between calls.
-}
module Concordance.Embedding (
    Profile (..),
    Embedder (..),
    openEmbedder,
    closeEmbedder,
    embedText,
) where

import qualified Concordance.WordPiece as WordPiece
import qualified Data.ByteString.Char8 as BS
import qualified Foreign.C.String as CStr
import qualified Foreign.Marshal.Alloc as Alloc
import qualified Foreign.Ptr as Ptr
import qualified Foreign.Storable as Storable

foreign import ccall "concordance_shim.h cn_embed_init"
    c_embedInit :: CStr.CString -> Int -> Int -> Int -> CStr.CString -> Int -> IO Int
foreign import ccall "concordance_shim.h cn_embed"
    c_embed :: Ptr.Ptr Int -> Int -> Ptr.Ptr Double -> IO Int
foreign import ccall "concordance_shim.h cn_embed_close"
    c_embedClose :: IO ()

{- | The embedding model profile (RFC-0034 decision 13). Pooling is 0 for
mean, 1 for CLS; the token cap includes the @[CLS]@/@[SEP]@ specials.
-}
data Profile = Profile
    { profileModelPath :: FilePath
    , profilePooling :: Int
    , profileDims :: Int
    , profileMaxTokens :: Int
    , profileThreads :: Int
    , profileQueryPrefix :: String
    }

-- | An embedding capability: token ids to a unit vector, or an error.
newtype Embedder = Embedder
    { embedTokens :: [Int] -> IO (Either String [Double])
    }

-- | The size of the error-message buffer passed to the shim.
errBufSize :: Int
errBufSize = 512

{- | Opens the ONNX model behind the shim and returns the real 'Embedder',
or the shim's error (also the "shim not built" case).
-}
openEmbedder :: Profile -> IO (Either String Embedder)
openEmbedder profile =
    CStr.withCAString (profileModelPath profile) $ \pathC ->
        Alloc.allocaBytes errBufSize $ \errC -> do
            rc <-
                c_embedInit
                    pathC
                    (profilePooling profile)
                    (profileDims profile)
                    (profileThreads profile)
                    errC
                    errBufSize
            if rc /= 0
                then Left <$> CStr.peekCAString errC
                else pure (Right (Embedder (ffiEmbed (profileDims profile))))

-- | Releases the shim's model session.
closeEmbedder :: IO ()
closeEmbedder = c_embedClose

-- | One embed call through the shim.
ffiEmbed :: Int -> [Int] -> IO (Either String [Double])
ffiEmbed dims ids =
    Alloc.allocaBytes (length ids * 8) $ \idsC ->
        Alloc.allocaBytes (dims * 8) $ \outC -> do
            mapM_ (uncurry (Storable.pokeElemOff idsC)) (zip [0 ..] ids)
            rc <- c_embed idsC (length ids) outC
            if rc /= 0
                then pure (Left ("embed failed (" ++ show rc ++ ")"))
                else Right <$> mapM (Storable.peekElemOff outC) [0 .. dims - 1]

{- | Tokenises and embeds one text through the given embedder: the single
path both indexing and queries use (a correctness requirement -- RFC-0034
decision 2).
-}
embedText ::
    Embedder -> WordPiece.Vocab -> Profile -> BS.ByteString -> IO (Either String [Double])
embedText embedder vocab profile text =
    embedTokens
        embedder
        (WordPiece.encodedIds (WordPiece.encode vocab (profileMaxTokens profile) text))
