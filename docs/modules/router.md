# Router Module Design

## Router Module Purpose

`MicroHttp.Router` maps parsed requests to handlers using value-level route
definitions.

## Router Module Responsibilities

- Match literal path segments.
- Match captured path segments.
- Dispatch by HTTP method.
- Return 404 when no route path matches.
- Return 405 when a path matches but the method does not.
- Pass captures to handlers.

## Router Module Non-Responsibilities

- Parsing raw HTTP requests.
- Serialising responses.
- Typed route-level API generation.
- Middleware composition.

## Router Module Public Interface Sketch

```haskell
type Handler = Captures -> Request -> IO Response

data Route

get :: RoutePattern -> Handler -> Route
post :: RoutePattern -> Handler -> Route
delete :: RoutePattern -> Handler -> Route

route :: [Route] -> Request -> IO Response
```

## Router Module Boundary Decision

The value-level router should be the first public router. It is simple, easy to
debug, and does not depend on advanced type-level machinery.

Typed routing should be layered on top by producing value-level `Route` values.
That keeps the value router as the runtime dispatch engine.
