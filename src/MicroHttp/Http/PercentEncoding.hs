{- | Percent-decoding for URL path segments and form values, shared by the
request parser and form handling. A literal @+@ means a space only in the
application/x-www-form-urlencoded form variant, never in a path segment.
-}
module MicroHttp.Http.PercentEncoding (
    decodePathSegment,
    decodeFormValue,
) where

import Data.Char (isDigit)

-- | Percent-decodes a path segment; a literal @+@ is kept.
decodePathSegment :: String -> String
decodePathSegment = decode False

-- | Percent-decodes a form value; a literal @+@ becomes a space.
decodeFormValue :: String -> String
decodeFormValue = decode True

decode :: Bool -> String -> String
decode _ [] = []
decode plusIsSpace ('%' : a : b : rest) =
    case hexPair a b of
        Just c -> c : decode plusIsSpace rest
        Nothing -> '%' : a : b : decode plusIsSpace rest
decode True ('+' : rest) = ' ' : decode True rest
decode plusIsSpace (c : rest) = c : decode plusIsSpace rest

hexPair :: Char -> Char -> Maybe Char
hexPair a b = (\high low -> toEnum (high * 16 + low)) <$> hexValue a <*> hexValue b

hexValue :: Char -> Maybe Int
hexValue c
    | isDigit c = Just (fromEnum c - fromEnum '0')
    | 'a' <= c && c <= 'f' = Just (10 + fromEnum c - fromEnum 'a')
    | 'A' <= c && c <= 'F' = Just (10 + fromEnum c - fromEnum 'A')
    | otherwise = Nothing
