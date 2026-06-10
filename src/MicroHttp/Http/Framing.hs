module MicroHttp.Http.Framing (
    FrameError (..),
    frameRequest,
) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isDigit, isSpace, toLower)
import MicroHttp.Http.Parser (ParseError (..), ParseLimits (..))

{- | A framing failure: either the transport failed, or the bytes received so
far cannot become a complete request within the configured limits.
-}
data FrameError e
    = FrameTransportError e
    | FrameParseError ParseError
    deriving (Eq, Show)

{- | Reads chunks from a source until one complete request is buffered:
headers up to the CRLFCRLF terminator, then a body of exactly the declared
Content-Length. The source yields an empty chunk at orderly end of stream.
Limits are enforced as data arrives.
-}
frameRequest ::
    IO (Either e BS.ByteString) ->
    ParseLimits ->
    IO (Either (FrameError e) BS.ByteString)
frameRequest source limits = collectHeaders BS.empty
  where
    collectHeaders buffered =
        case findHeaderTerminator buffered of
            Just headerLength -> startBody buffered headerLength
            Nothing
                | BS.length buffered > maxHeaderBytes limits + terminatorLength ->
                    return (Left (FrameParseError HeaderTooLarge))
                | otherwise -> do
                    next <- source
                    case next of
                        Left err -> return (Left (FrameTransportError err))
                        Right bytes
                            | BS.null bytes ->
                                return (Left (FrameParseError (BadRequest "incomplete request")))
                            | otherwise -> collectHeaders (BS.append buffered bytes)

    startBody buffered headerLength =
        case declaredContentLength (BSC.unpack (BS.take headerLength buffered)) of
            Left err -> return (Left (FrameParseError err))
            Right bodyLength
                | bodyLength > maxBodyBytes limits ->
                    return (Left (FrameParseError BodyTooLarge))
                | otherwise ->
                    collectBody (headerLength + terminatorLength + bodyLength) buffered

    collectBody totalLength buffered
        | BS.length buffered >= totalLength = return (Right (BS.take totalLength buffered))
        | otherwise = do
            next <- source
            case next of
                Left err -> return (Left (FrameTransportError err))
                Right bytes
                    | BS.null bytes ->
                        return (Left (FrameParseError (BadRequest "incomplete body")))
                    | otherwise -> collectBody totalLength (BS.append buffered bytes)

terminatorLength :: Int
terminatorLength = 4

findHeaderTerminator :: BS.ByteString -> Maybe Int
findHeaderTerminator bytes = go 0 (BSC.unpack bytes)
  where
    go _ [] = Nothing
    go index ('\r' : '\n' : '\r' : '\n' : _) = Just index
    go index (_ : rest) = go (index + 1) rest

{- | Reads the declared Content-Length from a raw header block, mirroring the
parser's semantics: missing means zero, non-numeric is a bad request.
-}
declaredContentLength :: String -> Either ParseError Int
declaredContentLength headerBlock =
    case contentLengthValues headerBlock of
        [] -> Right 0
        value : _
            | value /= "" && all isDigit value -> Right (read value)
            | otherwise -> Left (BadRequest "invalid content-length")

contentLengthValues :: String -> [String]
contentLengthValues headerBlock =
    [ trim value
    | line <- splitCrlf headerBlock
    , (name, ':' : value) <- [break (== ':') line]
    , map toLower (trim name) == "content-length"
    ]

splitCrlf :: String -> [String]
splitCrlf text =
    case break (== '\r') text of
        (line, '\r' : '\n' : rest) -> line : splitCrlf rest
        (line, _) -> [line]

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
