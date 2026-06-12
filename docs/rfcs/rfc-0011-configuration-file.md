---
id: RFC-0011
name: Configuration File
status: Draft
owners:
    - alistair
created: 2026-06-12
updated: 2026-06-12
supersedes: []
superseded_by: null
---

# Configuration File

| Stage     | Timestamp  |
|-----------|------------|
| Authored  | 2026-06-12 |
| Started   |            |
| Completed |            |

## Summary

Placeholder. Scope a configuration file so an operator can set server and
application options without recompiling. The first concrete requirement is the
access-log file location: RFC-0009 made the logger an injected component, and
the running TestApp currently wires a file logger to a hardcoded constant path
(see `## Context`). That constant should move into configuration.

## Context

This RFC is a placeholder to be fleshed out. The trigger is RFC-0009 request
logging: the logger and its destination are injected, but there is no way to
choose the destination without editing code. The TestApp entry point now wires
a `fileLogfmtLogger` at a constant path as an interim measure; the config file
must capture that location so it is operator-set rather than compiled in.

Other options likely to belong here (to be confirmed when this RFC is taken
up): host and port, the active-handler cap, the header/body byte limits, the
idle read and write timeouts (RFC-0006, RFC-0008), the document root, and the
static-file root and prefix (RFC-0010). The format, location, precedence
against any command-line or environment overrides, and parsing approach are
all open.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Capture the access-log file location in configuration, replacing the
  hardcoded constant the TestApp wires today.
- (To be expanded.) Decide which server and application options are
  configurable and how they are read.

## Non-Goals

- (To be expanded.)

## Proposal

To be written. Must at minimum specify how the access-log file location is
configured and threaded to `settingsLogger`.

## Alternatives Considered

- To be written (file format and source: a bespoke key/value file, an
  existing format, environment variables, or command-line flags).

## Security Impact

- A configuration file may name a log path and other paths; path handling and
  permissions need consideration when this RFC is taken up.

## Reliability Impact

- Behaviour when the file is missing or malformed (fail fast versus fall back
  to defaults) is to be decided.

## Compatibility Impact

- To be written.

## Testing and Quality Gates

- `make check` stays green.
- Additional tests to be defined when the RFC is taken up.

## Rollout Plan

1. Placeholder; rollout to be defined.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing
  the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- What configuration format and location, and what precedence against
  command-line or environment overrides?
- Which options are configurable, and what is the behaviour on a missing or
  malformed file?
