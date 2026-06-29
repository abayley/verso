{- | The faked author identity for RFC-0032 versioning. There is no
authentication: the acting author's name is read from a configurable request
header (by default @X-Remote-User@, the de-facto header a reverse proxy sets),
falling back to a configured default name when the header is absent or blank. The
git author email is synthesised deterministically from the name.

This module is the single seam where real authentication slots in later: an auth
middleware (or the existing reverse proxy) sets the header, or 'currentIdentity'
is reimplemented to read a session -- without touching any versioning code. The
identity is a label only; no authorization decision depends on it.

The pure core, 'deriveIdentity', takes the raw header value (if any) so it is
unit-testable without constructing a request.
-}
module Verso.Identity (
    IdentityConfig (..),
    currentIdentity,
    deriveIdentity,
) where

import qualified Data.ByteString.Char8 as BS
import qualified Data.Char as Char
import qualified MicroHttp.Http as Http
import qualified Verso.Git as Git

-- | The configuration 'currentIdentity' needs: which header to read, the fallback name, and the email domain.
data IdentityConfig = IdentityConfig
    { idcHeader :: String
    , idcDefault :: String
    , idcEmailDomain :: String
    }
    deriving (Eq, Show)

{- | Derives the acting author from the request: the configured identity header's
value, or the configured default name when it is absent or blank.
-}
currentIdentity :: IdentityConfig -> Http.RequestHead -> Git.Identity
currentIdentity cfg req = deriveIdentity cfg (headerValue (idcHeader cfg) req)

{- | The pure core of 'currentIdentity': given the raw header value (if present),
produce the commit identity, applying the default name and synthesising the email.
-}
deriveIdentity :: IdentityConfig -> Maybe String -> Git.Identity
deriveIdentity cfg raw =
    let name = case fmap trim raw of
            Just v | not (null v) -> v
            _ -> idcDefault cfg
        email = slug name ++ "@" ++ idcEmailDomain cfg
     in Git.Identity name email

-- | Looks up a header by case-insensitive name, returning its value as a 'String' when present.
headerValue :: String -> Http.RequestHead -> Maybe String
headerValue name req =
    fmap BS.unpack (lookup (Http.normaliseHeaderName (BS.pack name)) (Http.requestHeaders req))

-- | Lowercases the name and turns every non-alphanumeric character into a dash, for an email local-part.
slug :: String -> String
slug = map dashLower
  where
    dashLower c = if Char.isAlphaNum c then Char.toLower c else '-'

-- | Strips leading and trailing ASCII whitespace.
trim :: String -> String
trim = reverse . dropWhile Char.isSpace . reverse . dropWhile Char.isSpace
