module MicroHttp.Parser(parseRequest) where

import Data.Char
import MicroHttp.Http

parseRequest :: Int -> Int -> String -> Either ParseError Request
parseRequest maxHeaderBytes maxBodyBytes input =
  case breakOn "\r\n\r\n" input of
    Nothing -> Left (BadRequest "missing header terminator")
    Just (headerBlock, bodyWithSeparator) ->
      if length headerBlock > maxHeaderBytes then
        Left HeaderTooLarge
      else
        parseHeaderBlock maxBodyBytes headerBlock (drop 4 bodyWithSeparator)

parseHeaderBlock :: Int -> String -> String -> Either ParseError Request
parseHeaderBlock maxBodyBytes headerBlock remainingBody =
  case splitLines headerBlock of
    [] -> Left (BadRequest "empty request")
    requestLine:headerLines ->
      case words requestLine of
        [method, target, version] ->
          if version /= "HTTP/1.1" && version /= "HTTP/1.0" then
            Left UnsupportedHttpVersion
          else
            parseHeaders maxBodyBytes method target headerLines remainingBody
        _ -> Left (BadRequest "invalid request line")

parseHeaders :: Int -> String -> String -> [String] -> String -> Either ParseError Request
parseHeaders maxBodyBytes method target headerLines remainingBody =
  case traverse parseHeader headerLines of
    Left err -> Left err
    Right headers ->
      case lookupHeader "transfer-encoding" headers of
        Just value | map toLower value /= "identity" -> Left UnsupportedTransferEncoding
        _ ->
          let bodyLength = maybe 0 readInt (lookupHeader "content-length" headers)
          in if bodyLength > maxBodyBytes then
               Left BodyTooLarge
             else
               let (pathText, queryText) = splitTarget target
               in Right Request
                    { requestMethod = method
                    , requestPath = filter (/= "") (splitOn '/' pathText)
                    , requestQuery = parseQuery queryText
                    , requestHeaders = headers
                    , requestBody = take bodyLength remainingBody
                    , requestRawPath = pathText
                    }

parseHeader :: String -> Either ParseError (String, String)
parseHeader line =
  case break (== ':') line of
    (name, ':':value) -> Right (map toLower (trim name), trim value)
    _ -> Left (BadRequest ("invalid header: " ++ line))

lookupHeader :: String -> [(String, String)] -> Maybe String
lookupHeader _ [] = Nothing
lookupHeader name ((key, value):rest)
  | name == key = Just value
  | otherwise = lookupHeader name rest

splitTarget :: String -> (String, String)
splitTarget target =
  case break (== '?') target of
    (pathText, '?':queryText) -> (pathText, queryText)
    (pathText, _) -> (pathText, "")

parseQuery :: String -> [(String, String)]
parseQuery "" = []
parseQuery queryText = map parsePair (splitOn '&' queryText)
  where
    parsePair text =
      case break (== '=') text of
        (key, '=':value) -> (key, value)
        (key, _) -> (key, "")

readInt :: String -> Int
readInt text =
  case reads text of
    [(value, "")] -> value
    _ -> 0

splitLines :: String -> [String]
splitLines = splitOnString "\r\n"

splitOn :: Char -> String -> [String]
splitOn separator text =
  case break (== separator) text of
    (before, _:after) -> before : splitOn separator after
    (before, []) -> [before]

splitOnString :: String -> String -> [String]
splitOnString separator text =
  case breakOn separator text of
    Just (before, after) -> before : splitOnString separator (drop (length separator) after)
    Nothing -> [text]

breakOn :: String -> String -> Maybe (String, String)
breakOn needle haystack = go "" haystack
  where
    go _ [] = Nothing
    go prefix rest
      | needle `isPrefixOfLocal` rest = Just (reverse prefix, rest)
      | otherwise = go (head rest : prefix) (tail rest)

isPrefixOfLocal :: String -> String -> Bool
isPrefixOfLocal [] _ = True
isPrefixOfLocal _ [] = False
isPrefixOfLocal (x:xs) (y:ys) = x == y && isPrefixOfLocal xs ys

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
