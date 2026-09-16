{- | A small JSON value and its renderer (RFC-0046), for the wiki's API responses.
Domain renderers and request handlers build a 'Json' value; the response boundary
renders it once with 'render'. Holding the response as a value rather than a
concatenated string keeps one escaper -- correct to the JSON specification -- and
lets a test inspect a response as data.

The tree emits JSON but never reads it (the editor is the only reader, in
TypeScript), so there is no parser here. Every number the API emits is an integer,
so the value carries 'JInt' and no floating point. This is not the operation log's
on-disk format, which is 'Verso.OperationLog.renderOperation' and stays as it is.
-}
module Verso.Json (
    Json (..),
    object,
    array,
    string,
    int,
    bool,
    render,
) where

import qualified Data.Char as Char
import qualified Data.List as List
import qualified Numeric

-- | A JSON value: null, a boolean, an integer, a string, an array, or an object (ordered fields).
data Json
    = JNull
    | JBool Bool
    | JInt Int
    | JString String
    | JArray [Json]
    | JObject [(String, Json)]
    deriving (Eq, Show)

-- | An object from its ordered @(key, value)@ fields.
object :: [(String, Json)] -> Json
object = JObject

-- | An array from its items.
array :: [Json] -> Json
array = JArray

-- | A string value.
string :: String -> Json
string = JString

-- | An integer value.
int :: Int -> Json
int = JInt

-- | A boolean value.
bool :: Bool -> Json
bool = JBool

-- | Renders a JSON value to its compact text (no insignificant whitespace).
render :: Json -> String
render JNull = "null"
render (JBool True) = "true"
render (JBool False) = "false"
render (JInt n) = show n
render (JString s) = renderString s
render (JArray items) = "[" ++ List.intercalate "," (map render items) ++ "]"
render (JObject fields) = "{" ++ List.intercalate "," (map field fields) ++ "}"
  where
    field (key, value) = renderString key ++ ":" ++ render value

-- | Renders a JSON string literal, escaping to the JSON specification.
renderString :: String -> String
renderString s = "\"" ++ concatMap escape s ++ "\""

{- | Escapes one character for a JSON string: the two mandatory escapes (@\"@ and
@\\@), the short forms for the control characters that have them, and @\\u00XX@ for
every other control character below U+0020. Every character at or above U+0020
other than @\"@ and @\\@ is emitted as itself (a printable is not widened).
-}
escape :: Char -> String
escape '"' = "\\\""
escape '\\' = "\\\\"
escape '\b' = "\\b"
escape '\t' = "\\t"
escape '\n' = "\\n"
escape '\f' = "\\f"
escape '\r' = "\\r"
escape c
    | c < ' ' = "\\u" ++ pad (Numeric.showHex (Char.ord c) "")
    | otherwise = [c]
  where
    pad hex = replicate (4 - length hex) '0' ++ hex
