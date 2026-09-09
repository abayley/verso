---
id: ADR-0033
name: Configuration Via A key=value File With Environment Overrides
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0033: Configuration Via A key=value File With Environment Overrides

## Context

After RFC-0012 the operator-tunable knobs are split between the server
`Settings` (host, port, limits, timeouts) and the application composition (the
access-log path, document root, static mounts, parse limits), and both were
hardcoded. An operator needs to configure these without recompiling. MicroHs
has no TOML/JSON/YAML parser, so the format must be something trivially parsed
in-project.

## Decision

A `MicroHttp.Config` module parses a flat `key = value` file (blank
lines and `#` comments ignored, whitespace trimmed; a non-blank line without an
`=` is a `ConfigError`). `applyEnvironment` overlays `MICROHTTP_<KEY>`
environment entries onto the parsed config, winning over the file; precedence is
defaults, then file, then environment. `toSettings` maps the known server keys
onto `defaultSettings`, failing fast on a bad value; `configString`/`configInt`/
`configBool` read application keys with defaults, and `configMounts` parses a
comma-separated `<prefix> <root>` list for multiple static mounts. The
executable's `main` loads the config (path from `MICROHTTP_CONFIG`, default
`micro-http.conf`), builds the `Settings`, and composes the application from the
same config; a missing file uses defaults, a malformed file exits non-zero.
The design is RFC-0011.

## Consequences

zero-config still runs on defaults, and an operator configures via
a readable file or environment overrides. The config store is open (no fixed
schema), so the RFC's "warn on unknown keys" was dropped -- with app-defined
keys there is no closed key set to warn against. Environment overrides read
`getEnvironment`, which reflects variables present at launch (the production
case); under MicroHs a mid-process `setEnv` is not seen because `environ` is
snapshotted, so the override logic is unit-tested through the pure
`applyEnvironment` rather than a live `setEnv`. No secrets live in the config;
TLS remains the reverse proxy's concern (ADR-0031).
