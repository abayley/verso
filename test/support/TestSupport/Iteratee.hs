-- | Consumers shared by the iteratee and stream specs (RFC-0041).
module TestSupport.Iteratee (
    headOfEach,
) where

import qualified Data.ByteString as BS
import qualified MicroHttp.Iteratee as Iteratee

{- | A two-source consumer: the first chunk of the inner stream and the first
chunk of the outer (base-monad) stream.
-}
headOfEach :: Iteratee.IterT e (Iteratee.IterT e IO) (Maybe BS.ByteString, Maybe BS.ByteString)
headOfEach = do
    inner <- Iteratee.headChunk
    outer <- Iteratee.lift Iteratee.headChunk
    pure (inner, outer)
