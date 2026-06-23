{- | The trash provenance manifest (RFC-0028, phase 2). A delete moves a page or
section out of the corpus into a trash entry rather than destroying it; the entry's
manifest records where it came from so 'restore' is a uniform inverse: each trashed
item carries its stored name (inside the entry), whether it is a directory, and its
origin tree path, so restore moves every item back to exactly where it was.

The manifest render/parse is pure and round-trips. The format is a simple line-based
one (not nested JSON) so it parses without a JSON object parser: a @path@/@kind@/@seq@
header then one @item:@ line per stored file or directory.
-}
module MicroHttp.Trash (
    TrashItem (..),
    Manifest (..),
    renderManifest,
    parseManifest,
) where

import Data.List (isPrefixOf)
import Data.Maybe (mapMaybe)

-- | One stored file or directory in a trash entry: its name inside the entry, whether it is a directory, and its origin tree path.
data TrashItem = TrashItem
    { itemStored :: String
    , itemIsDir :: Bool
    , itemOrigin :: String
    }
    deriving (Eq, Show)

{- | A trash entry's provenance: the deleted item's original tree path, its kind
(@page@/@section@), the originating operation-log @seq@, and the stored items to
restore.
-}
data Manifest = Manifest
    { manPath :: String
    , manKind :: String
    , manSeq :: Int
    , manListing :: Maybe String
    , manItems :: [TrashItem]
    }
    deriving (Eq, Show)

-- | Renders a manifest as its line-based text (header lines, optional listing line, then one @item:@ line each).
renderManifest :: Manifest -> String
renderManifest manifest =
    unlines
        ( ["path: " ++ manPath manifest, "kind: " ++ manKind manifest, "seq: " ++ show (manSeq manifest)]
            ++ maybe [] (\listing -> ["listing: " ++ listing]) (manListing manifest)
            ++ map renderItem (manItems manifest)
        )
  where
    renderItem item =
        "item: " ++ itemStored item ++ " " ++ (if itemIsDir item then "dir" else "file") ++ " " ++ itemOrigin item

-- | Parses a manifest, or 'Nothing' when a required header is missing or malformed.
parseManifest :: String -> Maybe Manifest
parseManifest text = do
    let ls = lines text
    pathLine <- optField "path: " ls
    kindLine <- optField "kind: " ls
    seqLine <- optField "seq: " ls
    seqVal <- readInt seqLine
    pure
        Manifest
            { manPath = pathLine
            , manKind = kindLine
            , manSeq = seqVal
            , manListing = optField "listing: " ls
            , manItems = mapMaybe parseItem ls
            }
  where
    optField prefix ls = case [drop (length prefix) l | l <- ls, prefix `isPrefixOf` l] of
        (value : _) -> Just value
        [] -> Nothing

-- | Parses one @item: <stored> <file|dir> <origin>@ line.
parseItem :: String -> Maybe TrashItem
parseItem line
    | not ("item: " `isPrefixOf` line) = Nothing
    | otherwise = case words (drop (length "item: ") line) of
        (stored : typ : originWords@(_ : _)) ->
            Just (TrashItem stored (typ == "dir") (unwords originWords))
        _ -> Nothing

-- | Parses a non-negative integer, or 'Nothing'.
readInt :: String -> Maybe Int
readInt s = case reads s of
    [(n, "")] -> Just n
    _ -> Nothing
