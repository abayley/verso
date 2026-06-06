module MicroHttp.Http.Parser (
    ParseError (..),
    ParseLimits (..),
    defaultParseLimits,
    parseRequest,
) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isAsciiUpper, isDigit, isSpace)
import MicroHttp.Http

data ParseLimits = ParseLimits
    { maxHeaderBytes :: Int
    , maxBodyBytes :: Int
    }
    deriving (Eq, Show)

defaultParseLimits :: ParseLimits
defaultParseLimits =
    ParseLimits
        { maxHeaderBytes = 8192
        , maxBodyBytes = 1048576
        }

data ParseError
    = BadRequest String
    | HeaderTooLarge
    | BodyTooLarge
    | UnsupportedMethod BS.ByteString
    | UnsupportedTransferEncoding
    | UnsupportedHttpVersion
    deriving (Eq, Show)

parseRequest :: ParseLimits -> BS.ByteString -> Either ParseError Request
parseRequest limits input =
    case breakOn "\r\n\r\n" (BSC.unpack input) of
        Nothing -> Left (BadRequest "missing header terminator")
        Just (headerBlock, bodyWithSeparator) ->
            if length headerBlock > maxHeaderBytes limits
                then
                    Left HeaderTooLarge
                else
                    parseHeaderBlock limits headerBlock (drop 4 bodyWithSeparator)

parseHeaderBlock :: ParseLimits -> String -> String -> Either ParseError Request
parseHeaderBlock limits headerBlock remainingBody =
    case splitLines headerBlock of
        [] -> Left (BadRequest "empty request")
        requestLine : headerLines ->
            case words requestLine of
                [methodToken, target, version] ->
                    case parseMethod (BSC.pack methodToken) of
                        Nothing -> Left (UnsupportedMethod (BSC.pack methodToken))
                        Just method ->
                            if version /= "HTTP/1.1" && version /= "HTTP/1.0"
                                then
                                    Left UnsupportedHttpVersion
                                else
                                    parseHeaders limits method target headerLines remainingBody
                _ -> Left (BadRequest "invalid request line")

parseHeaders :: ParseLimits -> Method -> String -> [String] -> String -> Either ParseError Request
parseHeaders limits method target headerLines remainingBody =
    case traverse parseHeader headerLines of
        Left err -> Left err
        Right headers ->
            case lookupHeader "transfer-encoding" headers of
                Just value
                    | BSC.unpack (lowerBytes value) /= "identity" ->
                        Left UnsupportedTransferEncoding
                _ ->
                    case contentLength headers of
                        Left err -> Left err
                        Right bodyLength ->
                            if bodyLength > maxBodyBytes limits
                                then
                                    Left BodyTooLarge
                                else
                                    let (rawPath, queryText) = splitTarget target
                                     in Right
                                            Request
                                                { requestMethod = method
                                                , requestPath = pathSegments rawPath
                                                , requestQuery = parseQuery queryText
                                                , requestHeaders = headers
                                                , requestBody = BSC.pack (take bodyLength remainingBody)
                                                , requestRawPath = BSC.pack rawPath
                                                }

parseHeader :: String -> Either ParseError Header
parseHeader line =
    case break (== ':') line of
        (name, ':' : value) ->
            Right (normaliseHeaderName (BSC.pack (trim name)), BSC.pack (trim value))
        _ -> Left (BadRequest ("invalid header: " ++ line))

lookupHeader :: String -> Headers -> Maybe BS.ByteString
lookupHeader _ [] = Nothing
lookupHeader name ((key, value) : rest)
    | normaliseHeaderName (BSC.pack name) == key = Just value
    | otherwise = lookupHeader name rest

contentLength :: Headers -> Either ParseError Int
contentLength headers =
    case lookupHeader "content-length" headers of
        Nothing -> Right 0
        Just value ->
            case readInt (BSC.unpack value) of
                Just size -> Right size
                Nothing -> Left (BadRequest "invalid content-length")

splitTarget :: String -> (String, String)
splitTarget target =
    case break (== '?') target of
        (pathText, '?' : queryText) -> (pathText, queryText)
        (pathText, _) -> (pathText, "")

pathSegments :: String -> [String]
pathSegments pathText =
    map percentDecode (filter (/= "") (splitOn '/' pathText))

parseQuery :: String -> [(String, String)]
parseQuery "" = []
parseQuery queryText = map parsePair (splitOn '&' queryText)
  where
    parsePair text =
        case break (== '=') text of
            (key, '=' : value) -> (percentDecode key, percentDecode value)
            (key, _) -> (percentDecode key, "")

percentDecode :: String -> String
percentDecode [] = []
percentDecode ('%' : a : b : rest) =
    case hexPair a b of
        Just c -> c : percentDecode rest
        Nothing -> '%' : a : b : percentDecode rest
percentDecode ('+' : rest) = ' ' : percentDecode rest
percentDecode (c : rest) = c : percentDecode rest

hexPair :: Char -> Char -> Maybe Char
hexPair a b =
    case (hexValue a, hexValue b) of
        (Just high, Just low) -> Just (toEnum (high * 16 + low))
        _ -> Nothing

hexValue :: Char -> Maybe Int
hexValue c
    | isDigit c = Just (fromEnum c - fromEnum '0')
    | 'a' <= c && c <= 'f' = Just (10 + fromEnum c - fromEnum 'a')
    | 'A' <= c && c <= 'F' = Just (10 + fromEnum c - fromEnum 'A')
    | otherwise = Nothing

readInt :: String -> Maybe Int
readInt text
    | text /= "" && all isDigit text = Just (read text)
    | otherwise = Nothing

splitLines :: String -> [String]
splitLines = splitOnString "\r\n"

splitOn :: Char -> String -> [String]
splitOn separator text =
    case break (== separator) text of
        (before, _ : after) -> before : splitOn separator after
        (before, []) -> [before]

splitOnString :: String -> String -> [String]
splitOnString separator text =
    case breakOn separator text of
        Just (before, after) ->
            before : splitOnString separator (drop (length separator) after)
        Nothing -> [text]

breakOn :: String -> String -> Maybe (String, String)
breakOn needle = go ""
  where
    go _ [] = Nothing
    go prefix rest
        | needle `isPrefixOfLocal` rest = Just (reverse prefix, rest)
        | otherwise = go (head rest : prefix) (tail rest)

isPrefixOfLocal :: String -> String -> Bool
isPrefixOfLocal [] _ = True
isPrefixOfLocal _ [] = False
isPrefixOfLocal (x : xs) (y : ys) = x == y && isPrefixOfLocal xs ys

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

lowerBytes :: BS.ByteString -> BS.ByteString
lowerBytes value =
    BSC.pack (map lowerAscii (BSC.unpack value))

lowerAscii :: Char -> Char
lowerAscii c
    | isAsciiUpper c = toEnum (fromEnum c + 32)
    | otherwise = c
