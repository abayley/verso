---
id: RFC-0030
name: Separate the MicroHttp framework from the Verso wiki application
status: Draft
owners:
    - alistair
created: 2026-06-28
updated: 2026-06-28
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Separate the MicroHttp framework from the Verso wiki application

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-28       |
| Started   | 2026-06-28       |
| Completed |                  |

## Summary

The codebase intermingles a small general-purpose web framework with a Markdown
wiki application. This RFC separates them by module namespace: the framework
keeps the `MicroHttp.*` namespace; the wiki application moves to a new `Verso.*`
namespace. The split is a structural reorganisation (module moves, import
rewrites, test relocations, build/tooling updates) plus one behavioural change:
application configuration keys gain a `VERSO_` environment-override prefix
distinct from the framework's `MICROHTTP_`. The expected outcome is a clean
downward dependency (`Verso.*` depends on `MicroHttp.*`, never the reverse) and a
framework that could be reused by a different application.

## Context

`src/MicroHttp/` currently holds two concerns side by side:

- A web framework: HTTP parsing, streaming iteratee core, sockets, server
  runtime, routing, static files, middleware, logging, HTML builder, config,
  filesystem primitives.
- A Markdown wiki: document tree, link graph/index, listings, sidecar metadata,
  attachments, in-server move/delete, operation log, trash, and the app
  assembly that wires routes.

Nothing in the framework set depends on the wiki set, with one exception
discovered during analysis (see Proposal: `FileOps`). The separation is
therefore mostly mechanical, but it is broad: ~10 domain modules, the app
assembly, two executables, ~14 test specs, the editor TypeScript tree, and the
build/tooling files all carry the `TestApp`/`MicroHttp` naming.

The application is named **Verso** (the back face of a leaf) -- evoking the
editor's dual nature, the same source rendered two ways (Markdown source and
WYSIWYG).

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist. Run `make format` then `make check` (green)
before each commit. Commit per phase.

## Goals

- Framework lives under `MicroHttp.*`; wiki application lives under `Verso.*`.
- Strict downward dependency: `Verso.*` may import `MicroHttp.*`; the reverse is
  forbidden.
- Framework provides generic config machinery; the application creates both the
  framework `Settings` and its own typed `Verso.Config`.
- Application-key environment overrides use the `VERSO_` prefix; framework-key
  overrides keep `MICROHTTP_`.
- `make check` stays green at every commit; behaviour is unchanged except the new
  `VERSO_` override prefix.

## Non-Goals

- No change to runtime behaviour, routes, or wire format (other than the
  `VERSO_` env prefix).
- No performance work; no change to the link index, move/delete, or trash logic.
- No `.cabal`/`mcabal` migration; the build stays Makefile + `mhs`.
- No redesign of the config file format; it remains a single flat file.
- No renaming of served asset paths (`static/editor/markdown-editor.js` etc.).

## Proposal

### Final module map

Framework (stays under `MicroHttp.*`, file locations unchanged unless noted):

- `MicroHttp` (umbrella -- unchanged; it already re-exports only framework modules)
- `MicroHttp.Html`
- `MicroHttp.Http` (+ `Http.Framing`, `Http.Parse`, `Http.Parser`,
  `Http.PercentEncoding`, `Http.Response`)
- `MicroHttp.Iteratee`, `MicroHttp.Stream`
- `MicroHttp.Network.Socket`
- `MicroHttp.Server`, `MicroHttp.Settings`
- `MicroHttp.Config` (generic machinery only -- see below)
- `MicroHttp.Middleware`, `MicroHttp.Log`
- `MicroHttp.Router`, `MicroHttp.Static`
- `MicroHttp.FileSystem` (renamed from `MicroHttp.FileOps`)

Application (moves to `Verso.*`):

- `Verso.DocumentLinks`, `Verso.LinkIndex`, `Verso.LinkIndexStore`,
  `Verso.LinkFingerprint`
- `Verso.DocumentListing`, `Verso.DocumentMeta`, `Verso.Attachment`
- `Verso.TreeMove`, `Verso.OperationLog`, `Verso.Trash`
- `Verso.Config` (application keys + `VERSO_` env overrides -- new module)
- `Verso.App` (the routed application assembly, renamed from `MicroHttp.TestApp`)

Executables:

- `src/Verso/Main.hs` (`module Main`) -- the server, from `src/TestApp.hs`
- `src/Verso/ReplayTool.hs` (`module Main`) -- from `src/ReplayTool.hs`

Build outputs: `build/test-app` -> `build/verso`; `build/replay-tool` unchanged.

### `FileOps` -> `MicroHttp.FileSystem` (framework)

Analysis correction: `FileOps` is not app-only. Its whole surface is generic
libc primitives (`renamePath`, `removeFilePath`, `removeEmptyDir`, `fileStat`
binding `rename(2)`/`unlink(2)`/`rmdir(2)`/`stat(2)`) with no document/wiki
semantics, and `MicroHttp.Log` (framework log rotation, RFC-0024) already imports
`renamePath`/`removeFilePath` from it. The module's own doc comment records that
these were consolidated out of `Log` to avoid duplicating the libc escape hatch
(ADR-061). It is therefore a framework portability shim. It stays in the
framework and is renamed `MicroHttp.FileSystem` to reflect what it is. This
preserves the downward dependency (`Log` -> `FileSystem`, both framework; the app
also depends on it downward).

### Config split

`MicroHttp.Config` keeps the generic machinery: the `Config` type, `ConfigError`,
`parseConfig`, `loadConfig`, `applyEnvironment`, the typed lookups
(`configString`, `configInt`, `configBool`, `configMounts`), and `toSettings`
plus `configHost` (these map onto the framework's own `Settings`).

`applyEnvironment` currently hardcodes the `MICROHTTP_` prefix and overlays *any*
matching key. It is parameterised by both prefix and the key set the prefix
owns, so the framework overlay (`MICROHTTP_` over `serverEnvKeys`) and the
application overlay (`VERSO_` over `appEnvKeys`) touch disjoint key domains and
neither leaks into the other (decision: strict partitioning -- a bare prefix
list, as first sketched, would let `VERSO_PORT` set the framework `port` and so
fail the "no leak into framework keys" requirement). Final shapes:

- `applyEnvironment :: String -> [String] -> [(String, String)] -> Config -> Config`
  (prefix, owned keys, environment, config; an entry `PREFIX_foo` overrides key
  `foo` only when `foo` is owned).
- `loadConfigWith :: [(String, [String])] -> FilePath -> IO (Either ConfigError Config)`
  (reads file + environment once, applies each `(prefix, ownedKeys)` overlay).
- `serverEnvKeys :: [String]` (framework) lists the nine `toSettings` keys.

`Verso.Config` owns `appEnvKeys :: [String]` and provides the application's single
loader:

- `loadConfig = loadConfigWith [("MICROHTTP_", serverEnvKeys), ("VERSO_", appEnvKeys)]`.

Both application entry points (`Main`, `ReplayTool`) call `Verso.Config.loadConfig`.

Consequence (intended): application keys are no longer overridable via
`MICROHTTP_<KEY>` (only `VERSO_<KEY>`); framework keys remain `MICROHTTP_<KEY>`
only. `MICROHTTP_CONFIG` (the config-file path, read via `lookupEnv`, not the
overlay) is unaffected.

`Verso.Config` (new) owns the application keys and exposes a typed record built
once:

- `data VersoConfig = VersoConfig { ... }` covering `document_tree_root`,
  `document_root`, `attachment_root`, `editor_theme`, `operation_log`,
  `trash_root`, `link_index`, `access_log`, `client_error_log`, `log_max_bytes`,
  `log_keep`, `static_mounts`.
- `fromConfig :: Config -> Either ConfigError VersoConfig`.

`Verso.App` and `Verso.ReplayTool` consume the typed `VersoConfig` instead of
poking the raw `Config` by string key.

Entry-point flow becomes:

```haskell
cfg      <- loadConfig ["MICROHTTP_", "VERSO_"] path  -- MicroHttp.Config
settings <- toSettings cfg                            -- framework Settings
versoCfg <- Verso.Config.fromConfig cfg               -- Verso.Config
```

### Editor TypeScript

`src/TestApp/Editor/` -> `src/Verso/Editor/` (49 files). Internal imports are
relative and unaffected; the references to update are the tooling files:
`knip.json` (entry + project globs), `package.json` (`editor:format`/`editor:lint`
path args), `tsconfig.json` (`include`), `scripts/build-editor.mjs`
(`entrypoints`), and any `test/editor/*.test.ts` imports that reach into
`../../src/TestApp/Editor`. The served bundle path
(`static/editor/markdown-editor.js`) does not change.

### Tests

Specs mirror their source module's namespace. App specs move
`test/{unit,integration}/MicroHttp/<X>Spec.hs` ->
`test/{unit,integration}/Verso/<X>Spec.hs` with `module Verso.<X>Spec`:
Attachment, DocumentLinks, DocumentListing, DocumentMeta, LinkFingerprint,
LinkIndex, LinkIndexStore, OperationLog, Trash, TreeMove, ClientError, and the
assembly spec `TestAppSpec` -> `Verso.AppSpec`. `FileOpsSpec` ->
`MicroHttp.FileSystemSpec` (stays framework). `ConfigSpec` splits: framework
`ConfigSpec` keeps generic + `MICROHTTP_` cases; a new `Verso.ConfigSpec` covers
`VersoConfig.fromConfig` and `VERSO_` overrides. The `test/unit/Main.hs` and
`test/integration/Main.hs` drivers are updated to import the relocated specs.

## Alternatives Considered

- App owns `FileOps`, framework `Log` re-duplicates `rename`/`unlink`: rejected.
  Reverses the ADR-061 consolidation and duplicates raw C bindings for no gain;
  the primitives have no app semantics.
- Single env prefix (`MICROHTTP_` for everything): rejected by decision. A
  distinct `VERSO_` prefix keeps the application's configuration surface legible
  as separate from the framework's.
- Two config files (framework + app): rejected. The module split does not
  require splitting the file; one file is simpler to operate.
- Leave the editor TS under `src/TestApp/Editor`: rejected by decision; the TS
  tree moves with the application for naming consistency.

## Security Impact

- None. No change to authentication/authorization (there is none), input
  validation, path handling, or the attachment/static serving paths. The
  `VERSO_` env overlay reads the same environment surface already read for
  `MICROHTTP_`.

## Reliability Impact

- No new failure modes. `FileSystem` keeps the ADR-061 return-code-checking
  contract verbatim. The config overlay change is additive (a second prefix
  pass); absent `VERSO_` vars, behaviour is identical to today.
- Risk is mechanical breakage during the move (a missed importer, a stale spec
  reference). Mitigated by `make check` green per phase and small commits.

## Compatibility Impact

- Internal: every `MicroHttp.<app-module>` import becomes `Verso.<module>`;
  `MicroHttp.FileOps` becomes `MicroHttp.FileSystem`. All within this repo.
- Operational: build output `build/test-app` -> `build/verso`; Makefile target
  `run-test-app` -> `run-verso`; `.claude/launch.json` and `scripts/http-bench.sh`
  updated. Operators using `MICROHTTP_CONFIG` are unaffected (that variable is
  unchanged). New `VERSO_*` overrides are available but optional.
- External: none. No public API or wire change.

## Testing and Quality Gates

- `make check` (markdownlint, fourmolu format-check, hlint, mhs unit +
  integration, editor-check) green before every commit.
- New `Verso.ConfigSpec`: `fromConfig` happy path, missing-key defaults, bad
  typed value error, and `VERSO_` override precedence (pure, via
  `applyEnvironment`).
- Framework `ConfigSpec` retains `MICROHTTP_` override coverage and confirms
  `VERSO_`-prefixed vars do not leak into framework keys.
- Existing specs must pass unchanged after relocation (no behavioural edits in
  the move phases).

## Rollout Plan

Each phase is one commit, `make check` green before committing.

1. **[DONE -- afaf457] Phase 1 -- `FileOps` -> `MicroHttp.FileSystem`.** Rename
   module + file; update importers (`MicroHttp.Log`, the app move/delete modules)
   and `FileOpsSpec` -> `MicroHttp.FileSystemSpec` + driver. Smallest, isolated.
2. **[DONE] Phase 2 -- Config split.** `applyEnvironment` parameterised by
   prefix + owned keys and `loadConfigWith` added in `MicroHttp.Config`
   (`serverEnvKeys` exported); `Verso.Config` added (`VersoConfig`, `fromConfig`,
   `appEnvKeys`, orchestrating `loadConfig`); `Verso.ConfigSpec` added; framework
   `ConfigSpec` updated (unit + integration). Entry points use
   `Verso.Config.loadConfig`. `VersoConfig` is consumed by the assembly in Phase 4;
   the `VERSO_`/`MICROHTTP_` partition is live now. (Behavioural change.)
3. **[DONE] Phase 3 -- Move app domain modules.** `MicroHttp.{DocumentLinks,
   LinkIndex, LinkIndexStore, LinkFingerprint, DocumentListing, DocumentMeta,
   Attachment, TreeMove, OperationLog, Trash}` -> `Verso.*`: module headers + all
   importers + relocated specs + test driver. (`MicroHttp.TestApp` and
   `ReplayTool` import `Verso.*` until renamed in phase 4 -- transient, no cycle.)
4. **[DONE] Phase 4 -- Rename the app assembly + executables.**
   `MicroHttp.TestApp` -> `Verso.App`; `src/TestApp.hs` -> `src/Verso/Main.hs`;
   `src/ReplayTool.hs` -> `src/Verso/ReplayTool.hs`; `MicroHttp.TestAppSpec` ->
   `Verso.AppSpec` and `MicroHttp.ClientErrorSpec` -> `Verso.ClientErrorSpec`
   (unit + integration); qualified aliases `TestApp` -> `App`. Updated Makefile
   (`build/test-app` -> `build/verso`, `run-test-app` -> `run-verso`),
   `.claude/launch.json`, `scripts/http-bench.sh`, `scripts/editor-smoke.cjs`.
5. **[DONE] Phase 5 -- Move editor TS.** `src/TestApp/Editor` ->
   `src/Verso/Editor`; updated `knip.json`, `package.json`, `tsconfig.json`,
   `scripts/build-editor.mjs`, 21 `test/editor` import paths, and the dangling
   `spike/editor-lit` import. Served bundle path `static/editor/` unchanged.
   `editor-check` green.
6. **Phase 6 -- Docs + memory.** Update `docs/design/project-organisation.md`,
   `README.md`, add an ADR for the framework/app split, refresh the
   decision-register reference, and update the auto-memory index. Mark this RFC
   Completed and move it to `docs/rfcs/implemented/`.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts do
  not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Resolved Questions

- Executable placement: entries stay under `src/` (`src/Verso/Main.hs`,
  `src/Verso/ReplayTool.hs`), keeping the `-isrc` build flag unchanged. The
  `app/Main.hs` convention in `docs/design/project-organisation.md` is deferred.
  (Decided 2026-06-28.)
- No `Verso` umbrella module yet; it is not required for the split. (Decided
  2026-06-28.)
- The assembly module is `Verso.App`. (Decided 2026-06-28.)

## Open Questions

- None.
