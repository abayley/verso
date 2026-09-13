{- | Test support shared by the unit and integration suites: collapsing any
response body to a strict one so its bytes can be inspected.
-}
module TestSupport.ResponseBody (
    materialiseBody,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.IORef as IORef
import qualified MicroHttp.Http as Http
import qualified MicroHttp.Iteratee as Iteratee

{- | Collapses any response body to a strict one: a file is read, a stream (sized
or close-delimited, RFC-0040) is run to completion. A stream that fails is a test
defect, so it is raised rather than returned.
-}
materialiseBody :: Http.Response -> IO Http.Response
materialiseBody response =
    case Http.responseBody response of
        Http.StrictBody _ -> pure response
        Http.FileBody path _ -> do
            bytes <- BS.readFile path
            pure response{Http.responseBody = Http.StrictBody bytes}
        Http.StreamBody enumerator -> collect enumerator
        Http.SizedStreamBody _ enumerator -> collect enumerator
  where
    collect enumerator = do
        acc <- IORef.newIORef []
        final <- enumerator (Iteratee.byteSinkI (\bytes -> IORef.modifyIORef acc (bytes :) >> pure (Right ())))
        result <- Iteratee.run final
        case result of
            Right () -> do
                chunks <- IORef.readIORef acc
                pure response{Http.responseBody = Http.StrictBody (BS.concat (reverse chunks))}
            Left err -> error ("materialiseBody: " ++ show err)
