{- | Content fingerprints for the Concordance search index (RFC-0034):
FNV-1a 64 over raw bytes, rendered as sixteen lowercase hex digits. Change
detection only -- no cryptographic claim. This pure implementation is the
reference the C shim's hash must agree with; production reconcile may call
either.
-}
module Concordance.Fingerprint (
    contentFingerprint,
    contentFingerprintFile,
) where

import qualified Data.Bits as Bits
import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import Data.Word (Word64)
import qualified MicroHttp.Bytes as Bytes
import qualified MicroHttp.Stream as Stream

-- | The FNV-1a 64 fingerprint of the bytes, as 16 lowercase hex digits.
contentFingerprint :: BS.ByteString -> String
contentFingerprint bytes = toHex (Bytes.foldl' step fnvOffset bytes)

{- | The fingerprint of a file's bytes, read in blocks so the file is never held
whole (RFC-0040): FNV-1a is a left fold, so folding block after block gives the
same 64-bit state, and hence the same digest, as folding the whole file at once.
Used by reconcile to hash a page for change detection without reading it into the
heap. A file that will not open is a 'Stream.StreamError'.
-}
contentFingerprintFile :: FilePath -> IO (Either Stream.StreamError String)
contentFingerprintFile path =
    fmap (fmap toHex) (Stream.foldFileBlocks fingerprintBlockBytes foldBlock fnvOffset path)
  where
    foldBlock acc block = pure (Bytes.foldl' step acc block)

-- | The block size for the streamed fingerprint.
fingerprintBlockBytes :: Int
fingerprintBlockBytes = 65536

-- | One FNV-1a 64 step: xor in the byte, multiply by the prime.
step :: Word64 -> Char -> Word64
step acc c = (acc `Bits.xor` fromIntegral (Char.ord c)) * fnvPrime

fnvOffset :: Word64
fnvOffset = 14695981039346656037

fnvPrime :: Word64
fnvPrime = 1099511628211

-- | Sixteen lowercase hex digits, zero-padded.
toHex :: Word64 -> String
toHex w = [hexDigit (fromIntegral ((w `div` (16 ^ p)) `mod` 16)) | p <- [15, 14 .. 0 :: Int]]
  where
    hexDigit n = "0123456789abcdef" !! n
