{- | The append-only operation log for the navigation tree's structural operations
(RFC-0028, phase 1). Each line is one /logical/ operation -- a move, delete, or
restore as intent (kind + paths + slug-implicit-in-paths + seq + timestamp), not the
file-by-file rewrites RFC-0027 recomputes when the operation is applied. The log
lives outside the corpus at a configured path and is the durable overlay that
survives a source refresh, the basis for replay and undo (later phases).

The record render/parse is pure and round-trips; the IO is a plain append (the order
is apply-then-append, RFC-0028 reliability) and a read. Paths are validated
tree-relative components (no quotes/backslashes), so the JSON values need no
escaping and parse by a simple top-level split.
-}
module Verso.OperationLog (
    OpType (..),
    Operation (..),
    renderOperation,
    parseOperation,
    readOperations,
    appendOperation,
    nextSeq,
) where

import qualified Data.ByteString.Char8 as BS
import Data.List (intercalate)
import Data.Maybe (mapMaybe)
import System.Directory (doesFileExist)

-- | The kind of a logical operation.
data OpType = OpMove | OpDelete | OpRestore
    deriving (Eq, Show)

{- | One logical operation. A @move@ has both 'opFrom' and 'opTo'; a @delete@ has
'opFrom' (and a 'opTrash' entry id); a @restore@ has 'opTo' (its origin) and
'opTrash'. 'opKind' is @"page"@ or @"section"@. 'opSeq' is monotonic; 'opTs' is
stamped by the caller (the server reads the clock, the log does not).
-}
data Operation = Operation
    { opType :: OpType
    , opKind :: String
    , opFrom :: Maybe String
    , opTo :: Maybe String
    , opSeq :: Int
    , opTs :: String
    , opTrash :: Maybe String
    }
    deriving (Eq, Show)

-- | Renders an operation as one JSON line (no trailing newline).
renderOperation :: Operation -> String
renderOperation op =
    "{" ++ intercalate "," fields ++ "}"
  where
    fields =
        [str "type" (typeString (opType op)), str "kind" (opKind op)]
            ++ optional "from" (opFrom op)
            ++ optional "to" (opTo op)
            ++ ["\"seq\":" ++ show (opSeq op), str "ts" (opTs op)]
            ++ optional "trash" (opTrash op)
    str key value = "\"" ++ key ++ "\":\"" ++ value ++ "\""
    optional key = maybe [] (\value -> [str key value])

-- | The wire string for an operation type.
typeString :: OpType -> String
typeString OpMove = "move"
typeString OpDelete = "delete"
typeString OpRestore = "restore"

-- | Parses an operation type from its wire string.
parseType :: String -> Maybe OpType
parseType "move" = Just OpMove
parseType "delete" = Just OpDelete
parseType "restore" = Just OpRestore
parseType _ = Nothing

{- | Parses one JSON log line back to an 'Operation', or 'Nothing' when it is
malformed (missing a required field or an unknown type). The shape is a flat object
of string/number values with no nesting, so it parses by a top-level comma split.
-}
parseOperation :: String -> Maybe Operation
parseOperation line = do
    let body = stripBraces (trim line)
        pairs = mapMaybe toPair (splitTop body)
    typeStr <- lookup "type" pairs
    opT <- parseType typeStr
    kind <- lookup "kind" pairs
    seqStr <- lookup "seq" pairs
    seqVal <- readInt seqStr
    ts <- lookup "ts" pairs
    pure
        Operation
            { opType = opT
            , opKind = kind
            , opFrom = lookup "from" pairs
            , opTo = lookup "to" pairs
            , opSeq = seqVal
            , opTs = ts
            , opTrash = lookup "trash" pairs
            }
  where
    toPair piece = case break (== ':') piece of
        (rawKey, ':' : rawValue) -> Just (unquote (trim rawKey), unquote (trim rawValue))
        _ -> Nothing

-- | Reads every operation from the log file (empty when absent), in file order.
readOperations :: FilePath -> IO [Operation]
readOperations path = do
    exists <- doesFileExist path
    if not exists
        then pure []
        else fmap (mapMaybe parseOperation . lines . BS.unpack) (BS.readFile path)

-- | Appends one operation as a JSON line (apply-then-append; the file is created on first write).
appendOperation :: FilePath -> Operation -> IO ()
appendOperation path op = BS.appendFile path (BS.pack (renderOperation op ++ "\n"))

-- | The next monotonic sequence number for the log (one past the current maximum, 0 when empty).
nextSeq :: FilePath -> IO Int
nextSeq path = do
    ops <- readOperations path
    pure (if null ops then 0 else maximum (map opSeq ops) + 1)

-- | Strips one pair of surrounding double quotes, if present.
unquote :: String -> String
unquote s
    | length s >= 2 && head s == '"' && last s == '"' = init (drop 1 s)
    | otherwise = s

-- | Strips a leading @{@ and trailing @}@ (with no effect when absent).
stripBraces :: String -> String
stripBraces s =
    let s' = if not (null s) && head s == '{' then drop 1 s else s
     in if not (null s') && last s' == '}' then init s' else s'

-- | Splits a flat (non-nested) object body on top-level commas.
splitTop :: String -> [String]
splitTop s = case break (== ',') s of
    (piece, ',' : rest) -> piece : splitTop rest
    (piece, _) -> [piece]

-- | Parses a non-negative integer, or 'Nothing'.
readInt :: String -> Maybe Int
readInt s = case reads s of
    [(n, "")] -> Just n
    _ -> Nothing

trim :: String -> String
trim = f . f where f = reverse . dropWhile (== ' ')
