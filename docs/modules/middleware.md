# Middleware Module Design

## Middleware Module Purpose

`MicroHttp.Middleware` provides composable transformations around applications.

## Middleware Module Responsibilities

- Define the middleware type.
- Provide small reusable middleware functions.
- Keep request and response transformations explicit.
- Support htmx response helpers.

## Middleware Module Non-Responsibilities

- Routing.
- Socket handling.
- HTML rendering internals.
- Filesystem persistence.

## Middleware Module Public Interface Sketch

```haskell
type Application = Request -> IO Response
type Middleware = Application -> Application

withMaxBodySize :: Int -> Middleware
withMethodOverride :: Middleware
withHtmxFragments :: Middleware
```

## Middleware Module First Candidates

- Method override for forms.
- Request size guard.
- Basic request logging.
- htmx request detection helpers.

Middleware should not become a framework kitchen sink. Add functions only when
there is an application workflow that needs them.
