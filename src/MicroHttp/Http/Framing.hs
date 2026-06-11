module MicroHttp.Http.Framing (
    frameHeadersI,
) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import MicroHttp.Http.Parser (ParseError (..), ParseLimits (..))
import MicroHttp.Iteratee (Iter (..), Stream (..))
import MicroHttp.Stream (StreamError (..))

{- | Frames request headers as an iteratee: it accumulates input until the
CRLFCRLF terminator, enforcing 'maxHeaderBytes' incrementally. The result
is the header bytes before the terminator; the residue is the body prefix,
threaded onward by bind. End of stream before the terminator is an
incomplete request.
-}
frameHeadersI :: ParseLimits -> Iter StreamError BS.ByteString
frameHeadersI limits = go BS.empty
  where
    go buffered = NeedInput (consume buffered)
    consume buffered s = case s of
        Chunk bytes
            | BS.null bytes -> go buffered
            | otherwise -> scan (BS.append buffered bytes)
        EndOfStream Nothing ->
            IterFailed (StreamParseError (BadRequest "incomplete request")) (EndOfStream Nothing)
        EndOfStream (Just err) ->
            IterFailed err (EndOfStream (Just err))

    scan buffered =
        case BS.breakSubstring headerTerminator buffered of
            (before, after)
                | BS.null after ->
                    if BS.length buffered > maxHeaderBytes limits + terminatorLength
                        then IterFailed (StreamParseError HeaderTooLarge) (Chunk buffered)
                        else go buffered
                | otherwise ->
                    Done before (Chunk (BS.drop terminatorLength after))

headerTerminator :: BS.ByteString
headerTerminator = BSC.pack "\r\n\r\n"

terminatorLength :: Int
terminatorLength = 4
