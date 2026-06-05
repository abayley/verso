module MicroHttp.TypedRoute
  ( GET
  , End
  , Lit
  , Capture
  , FromPathPiece(..)
  , RouteSpec(..)
  , dispatchTyped
  ) where

import Data.Proxy
import Data.TypeLits
import MicroHttp.Http

data GET
data End method
data Lit (segment :: Symbol) next
data Capture (name :: Symbol) value next

class FromPathPiece a where
  fromPathPiece :: String -> Maybe a

instance FromPathPiece String where
  fromPathPiece = Just

instance FromPathPiece Int where
  fromPathPiece text =
    case reads text of
      [(value, "")] -> Just value
      _ -> Nothing

class RouteSpec spec handler | spec -> handler where
  routePattern :: Proxy spec -> [String]
  callRoute :: Proxy spec -> handler -> [String] -> Request -> Maybe Response

instance RouteSpec (End GET) (Request -> Response) where
  routePattern _ = []
  callRoute _ handler [] request = Just (handler request)
  callRoute _ _ _ _ = Nothing

instance forall segment next handler .
  (KnownSymbol segment, RouteSpec next handler) =>
  RouteSpec (Lit segment next) handler where
  routePattern _ = symbolVal (Proxy :: Proxy segment) : routePattern (Proxy :: Proxy next)
  callRoute _ handler (segment:rest) request
    | segment == symbolVal (Proxy :: Proxy segment) =
        callRoute (Proxy :: Proxy next) handler rest request
    | otherwise = Nothing
  callRoute _ _ [] _ = Nothing

instance forall name value next handler .
  (KnownSymbol name, FromPathPiece value, RouteSpec next handler) =>
  RouteSpec (Capture name value next) (value -> handler) where
  routePattern _ = (":" ++ symbolVal (Proxy :: Proxy name)) : routePattern (Proxy :: Proxy next)
  callRoute _ handler (segment:rest) request =
    case fromPathPiece segment of
      Just value -> callRoute (Proxy :: Proxy next) (handler value) rest request
      Nothing -> Nothing
  callRoute _ _ [] _ = Nothing

dispatchTyped :: RouteSpec spec handler => Proxy spec -> handler -> Request -> Response
dispatchTyped proxy handler request =
  case callRoute proxy handler (requestPath request) request of
    Just response -> response
    Nothing -> notFound
