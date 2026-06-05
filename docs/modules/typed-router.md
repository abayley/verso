# Typed Router Module Design

## Typed Router Module Purpose

`MicroHttp.Router.Typed` provides an optional typed route builder for users who
want typed captures without Servant-style type families.

## Typed Router Module Responsibilities

- Represent route paths at the type level using `Symbol`.
- Recover literal segment names with `KnownSymbol`.
- Parse typed captures with `FromPathPiece`.
- Compute handler types structurally using functional dependencies.
- Produce value-level routes for the runtime router.

## Typed Router Module Non-Responsibilities

- Runtime route dispatch.
- Request body decoding.
- Response content negotiation.
- API documentation generation.
- Client generation.

## Typed Router Module Public Interface Sketch

```haskell
data GET
data POST
data End method
data Lit (segment :: Symbol) next
data Capture (name :: Symbol) value next

class FromPathPiece a where
  fromPathPiece :: Text -> Maybe a

class RouteSpec spec handler | spec -> handler where
  toRoute :: Proxy spec -> handler -> Route
```

## Typed Router Module MicroHs Findings

Spike 8 proved that MicroHs accepts the fundep-based approach for a simple route:

```haskell
type TodoShow = Lit "todos" (Capture "id" Int (End GET))

todoShow :: Int -> Request -> Response
```

This is enough to justify a typed-route builder as an optional module.

## Typed Router Module Open Decisions

- Whether typed routes should be public in the first milestone or remain
  experimental.
- Whether typed routes should support query captures in the first version.
- Whether route errors from typed captures should become 404 or 400.
