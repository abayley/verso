{- | Middleware as 'Application' transformations (ADR-015). The taxonomy
mirrors where each kind touches the pipeline:

  * head-level middleware composes plain functions over the response and
    never touches a stream ('mapResponse');
  * ingress middleware lifts an enumeratee around the application's body
    consumption ('ingress');
  * egress middleware fuses an enumeratee onto the response body enumerator
    before the sink ('egress');
  * failure-handling middleware intercepts a terminal failure and yields a
    replacement response ('catchIter').
-}
module MicroHttp.Middleware (
    Middleware,
    mapResponse,
    ingress,
    egress,
    catchIter,
) where

import MicroHttp.Http (RequestHead, Response (..), ResponseBody (..))
import MicroHttp.Iteratee (Enumerator, Iter (..))
import MicroHttp.Stream (StreamError)

{- | A middleware wraps an application (ADR-015). This is the same shape as
the server's @Application@, stated structurally to avoid a module cycle.
-}
type Middleware = (RequestHead -> Iter StreamError Response) -> RequestHead -> Iter StreamError Response

{- | Head-level middleware: transform the response value, no streams. For
example, adding a header or rewriting the status.
-}
mapResponse :: (Response -> Response) -> Middleware
mapResponse f app request = fmap f (app request)

{- | Ingress middleware: lift an enumeratee around the application's body
consumption. For example, @ingress (takeN n)@ bounds the body the handler
may read.
-}
ingress :: (Iter StreamError Response -> Iter StreamError Response) -> Middleware
ingress stage app request = stage (app request)

{- | Egress middleware: fuse an enumeratee onto a streaming response body so
it runs before the sink. A strict body is left unchanged. For example, a
future compression stage.
-}
egress :: (Iter StreamError () -> Iter StreamError ()) -> Middleware
egress stage app request = fmap (fuseBody stage) (app request)

fuseBody :: (Iter StreamError () -> Iter StreamError ()) -> Response -> Response
fuseBody stage response =
    case responseBody response of
        StrictBody _ -> response
        StreamBody enumerator -> response{responseBody = StreamBody (fuse enumerator)}
  where
    fuse :: Enumerator StreamError () -> Enumerator StreamError ()
    fuse enumerator sink = enumerator (stage sink)

{- | Failure-handling middleware: intercept a terminal failure and answer
with a replacement response instead. Successful results pass through.
-}
catchIter :: (StreamError -> Response) -> Middleware
catchIter handler app request = recover (app request)
  where
    recover it = case it of
        Done a residue -> Done a residue
        NeedInput k -> NeedInput (recover . k)
        IterM m -> IterM (fmap recover m)
        IterFailed err _ -> pure (handler err)
