module MicroHttp.Http.Parser (
    ParseError (..),
    ParseLimits (..),
    defaultParseLimits,
    parseRequestHead,
) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (isAsciiUpper, isDigit, isSpace)
import MicroHttp.Http
import MicroHttp.Http.Parse (ParseError (..), ParseLimits (..), defaultParseLimits)

{- | Parses a framed header block (the bytes before the CRLFCRLF terminator,
which the framing iteratee has already located) into a 'RequestHead'. The
body is no longer the parser's concern: it is consumed downstream as a
stream. Header and body size limits are enforced by framing and the body
cap stage, not here.
-}
parseRequestHead :: BS.ByteString -> Either ParseError RequestHead
parseRequestHead input =
    case splitLines (BSC.unpack input) of
        [] -> Left (BadRequest "empty request")
        requestLine : headerLines ->
            case words requestLine of
                [methodToken, target, version] ->
                    case parseMethod (BSC.pack methodToken) of
                        Nothing -> Left (UnsupportedMethod (BSC.pack methodToken))
                        Just method ->
                            if version /= "HTTP/1.1" && version /= "HTTP/1.0"
                                then Left UnsupportedHttpVersion
                                else parseHeaders method target headerLines
                _ -> Left (BadRequest "invalid request line")

parseHeaders :: Method -> String -> [String] -> Either ParseError RequestHead
parseHeaders method target headerLines =
    case traverse parseHeader headerLines of
        Left err -> Left err
        Right headers ->
            case lookupHeader "transfer-encoding" headers of
                Just value
                    | BSC.unpack (lowerBytes value) /= "identity" ->
                        Left UnsupportedTransferEncoding
                _ ->
                    let (rawPath, queryText) = splitTarget target
                     in Right
                            RequestHead
                                { requestMethod = method
                                , requestPath = pathSegments rawPath
                                , requestQuery = parseQuery queryText
                                , requestHeaders = headers
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
