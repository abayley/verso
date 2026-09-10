---
id: RFC-0011
name: Configuration File
status: Implemented
owners:
    - alistair
created: 2026-06-12
updated: 2026-06-14
supersedes: []
superseded_by: null
---

# Configuration File

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-06-12            |
| Started   | 2026-06-14 18:30 NZST |
| Completed | 2026-06-14 19:36 NZST |

## Summary

Let an operator configure the server without recompiling, via a simple
`key = value` file with optional environment-variable overrides. Because
RFC-0012 moved logging, the body bound, and static mounts into the application
stack, configuration must drive both the server `Settings` and the
application-composition knobs (the access-log path, document root, static
mount, and parse limits). The executable's `main` is the single wiring point:
it loads the config, builds a `Settings`, and composes the application from the
same config. A missing file falls back to defaults so zero-config still runs; a
malformed file fails fast with a clear error rather than starting with
surprising values.

## Context

The original placeholder predated RFC-0012 and assumed the log location lived
in `Settings` (the old `settingsLogger`). RFC-0012 removed that: logging is now
a middleware the application composes, the body bound moved into
`Router.serveRoutes`, and static serving is a route (`Static.static`). So the
knobs an operator wants to set are split across two places today, both
hardcoded:

- Server `Settings` (`defaultSettings`): host, port, backlog,
  `maxActiveHandlers`, `maxHeaderBytes`, `maxBodyBytes`, `readBufferBytes`, the
  idle read and write timeouts.
- Application composition: the access-log path (`build/access.log` in
  `main`), the document root (`data/documents`), the static mount
  (`/static/editor` -> `static/editor`), and the `ParseLimits` the router uses.

A config file therefore has to feed both, and the second is code in `main` and
the application module, so configuration cannot magically drive it -- `main`
must read the config and compose accordingly.

Format is constrained by MicroHs: there is no TOML/JSON/YAML parser, and
writing one is not worth it. A `key = value` file parsed by a small in-project
parser is trivial and dependency-free, and `System.Environment` is available
for environment-variable overrides.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- A `key = value` configuration file, parsed by an in-project parser (no new
  dependency), with environment-variable overrides per key. Precedence:
  built-in defaults, overridden by the file, overridden by the environment.
- Configuration drives both the server `Settings` and the
  application-composition knobs (access-log path, document root, static mount,
  parse limits).
- A missing file uses defaults (zero-config runs); a malformed file (an
  unparseable line or a bad typed value for a known key) fails fast with a
  clear message.
- `main` is the single wiring point: load config, build `Settings`, compose the
  application; the library provides the parser and the `Settings` mapping, the
  application reads its own knobs.

## Non-Goals

- No TOML, JSON, or YAML (no MicroHs parser; not worth writing). No nested or
  per-route configuration; a flat `key = value` namespace.
- No live reload or file watching (hot reload is a separate backlog item).
- No secrets management; TLS and its keys are the reverse proxy's concern
  (ADR-0031), so the config holds no credentials today.
- Not a general typed-config framework; a small, fixed, documented schema.

## Proposal

### The module

A new `MicroHttp.Config`:

```haskell
data Config                                   -- a parsed key/value store (opaque)
data ConfigError                              -- a malformed line or bad value

parseConfig :: String -> Either ConfigError Config        -- parse file text
loadConfig  :: FilePath -> IO (Either ConfigError Config) -- read file (or
                                                          -- empty if absent),
                                                          -- then apply env
toSettings  :: Config -> Either ConfigError Settings      -- map the server keys

-- typed lookups for the application's own knobs, with a default
configString :: String -> String -> Config -> String
configInt    :: String -> Int    -> Config -> Either ConfigError Int
configBool   :: String -> Bool   -> Config -> Either ConfigError Bool
```

`loadConfig` reads the file if present (an absent file is an empty config, so
defaults apply), parses it, then overlays environment variables: for a key
`port`, the variable `MICROHTTP_PORT` overrides it. A syntactically bad line or
a present-but-unparseable typed value surfaces as `ConfigError`, which `main`
turns into a fail-fast exit.

### The format

```ini
# micro-http configuration
host = 0.0.0.0
port = 8080
max_body_bytes = 1048576
idle_read_timeout_micros = 30000000
access_log = build/access.log
document_root = data/documents
static_mounts = /static/editor static/editor, /assets public/assets
```

Lines are `key = value`; blank lines and `#` comments are ignored; surrounding
whitespace is trimmed. `host` parses a dotted quad (`0.0.0.0` -> `HostAny`,
`a.b.c.d` -> `HostIPv4`). Integer keys must parse as integers or it is a
`ConfigError`. `static_mounts` is a comma-separated list of mounts, each a
`<url-prefix> <filesystem-root>` pair (whitespace-separated); an empty or absent
value means no static routes.

### Wiring in main

`main` loads the config and composes both halves from it:

```haskell
main = do
    loaded <- loadConfig configPath
    case loaded >>= \c -> (,) c <$> toSettings c of
        Left err -> die (show err)                 -- fail fast
        Right (cfg, settings) ->
            serve settings (appFromConfig cfg)

appFromConfig cfg =
    logRequests (fileLogfmtLogger (configString "access_log" "build/access.log" cfg))
        (withErrorResponses
            (serveRoutes (limitsFromConfig cfg)
                (documentRoutes (configString "document_root" "data/documents" cfg)
                    ++ [static prefix root | (prefix, root) <- configMounts "static_mounts" cfg])))
```

`configMounts` parses the comma-separated `<prefix> <root>` list, so the
application turns each into a `static` route.

The library owns `Config`, the parser, and `toSettings`; the application owns
which keys it reads for its own composition. There is no auto-binding from
config to the stack, because the stack is composed in code.

### Config file discovery

A fixed default path (for example `micro-http.conf` in the working directory),
overridable by the `MICROHTTP_CONFIG` environment variable. Command-line flags
are out of scope here.

## Alternatives Considered

- TOML/JSON/YAML: no MicroHs parser, and writing a correct one is a project in
  itself; rejected in favour of `key = value`.
- Environment variables only (12-factor): easy and deploy-friendly, but
  unwieldy past a handful of keys and gives no single readable config artifact.
  Kept as the override mechanism, not the primary source.
- Driving the application stack automatically from config: impossible without a
  reflection-like binding, because the stack is composed in code (RFC-0012);
  `main` reads the config and composes instead.

## Security Impact

- The config file names filesystem paths (log, document root, static root); its
  permissions and the paths it points at are the operator's responsibility, and
  the static path-safety from RFC-0010 still applies to served files.
- No secrets are stored: TLS and credentials are the reverse proxy's concern
  (ADR-0031).

## Reliability Impact

- A missing file uses defaults, so the server still starts with no config.
- A malformed file fails fast with a clear error, so the server never starts
  with silently-wrong configuration.

## Compatibility Impact

- Additive: a new `MicroHttp.Config` module and a rewired `main`. `Settings`,
  the application contracts, and the handlers are unchanged.
- `defaultSettings` remains the source of the built-in defaults that `toSettings`
  overlays.

## Testing and Quality Gates

- `make check` stays green.
- Unit: `parseConfig` handles comments, blank lines, and whitespace; a bad
  integer value and a malformed line are `ConfigError`; `toSettings` maps known
  keys and leaves unset ones at their defaults; `configString`/`configInt`
  return defaults for absent keys.
- Unit: an environment override beats a file value (inject the lookup).
- Integration: loading a small config file yields the expected `Settings` and
  the application reflects the configured access-log path and document root.

## Rollout Plan

1. Phase one: the config module and wiring.
   - [x] `MicroHttp.Config`: `Config`, `ConfigError`, `parseConfig`,
         `loadConfig` (file plus environment), `applyEnvironment`, `toSettings`,
         and the typed lookups (`configString`/`configInt`/`configBool`/
         `configMounts`).
   - [x] `main` loads the config, builds `Settings`, and composes the
         application from it; fail fast on `ConfigError`.
   - [x] Unit and integration tests above; `make check` green.
   - [x] ADR-0033 for the configuration approach; an example
         (`micro-http.conf.example`).

Notes from implementation (recorded in ADR-0033): the config store is open (no
fixed schema), so the "warn on unknown keys" decision was dropped -- with
app-defined keys there is no closed key set to warn against. The env-override
logic was factored into the pure `applyEnvironment` and unit-tested there,
because `loadConfig` reads `getEnvironment`, and under MicroHs that reflects
variables present at launch but not a mid-process `setEnv` (the `environ`
snapshot), so a live-`setEnv` integration test is unreliable.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing the
  affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Resolved Decisions

- Unknown keys are ignored with a warning, so an older binary tolerates a newer
  config file (forward-compatible).
- Environment overrides apply uniformly: any key `foo` is overridden by
  `MICROHTTP_FOO`.
- Multiple static mounts are supported: `static_mounts` is a comma-separated
  list of `<prefix> <root>` pairs, which the application turns into one
  `static` route each.
- Typed validation of the known server keys runs eagerly in `toSettings` (so a
  bad value fails before `serve`); application-key accessors validate at access.

## Open Questions

- None outstanding; the decisions above settle the format, source, precedence,
  and error policy.
