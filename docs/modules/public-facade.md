# Public Facade Module Design

## Public Facade Module Purpose

`MicroHttp` is the public import for application authors who want the common
server, routing, response, and HTML helpers.

## Public Facade Module Responsibilities

- Re-export stable public types.
- Re-export the server entry point.
- Re-export common router constructors.
- Re-export common response helpers.
- Re-export common HTML helpers.

## Public Facade Module Non-Responsibilities

- Export internal socket FFI details.
- Export parser internals.
- Export experimental typed-router internals by default.
- Hide important effects or lifecycle requirements.

## Public Facade Module Export Policy

The facade should be conservative. Experimental or low-level modules can remain
importable directly but should not be re-exported from `MicroHttp` until their
contracts are stable.

Candidate first facade:

```haskell
module MicroHttp
  ( serve
  , Settings(..)
  , Application
  , Request(..)
  , Response
  , get
  , post
  , delete
  , route
  , html
  , text
  , notFound
  , module MicroHttp.Html
  ) where
```
