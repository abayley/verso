# Agent Instructions

## Repository Layout

The code is split into packages under `packages/` (RFC-0038): `micro-http` is the
framework, a MicroCabal package; `verso` is the wiki application (Haskell under
`src/Verso` and `src/Concordance`, the Concordance cbits, and the served
`static/`); `verso-editor` is the TypeScript editor. The Verso build resolves the
framework from the MicroHs package database, and `make` reinstalls it with `mcabal
install` whenever `packages/micro-http` sources change, so an ordinary `make check`
picks up framework edits with no manual step. The full tree is in the top-level
`README.md`.

## Visual Work

Do not use strict TDD for exploratory visual work, including styling changes,
toolbar layout experiments, and UI control comparisons.

For visual work:

- Iterate browser-first against a running preview (see "Running the App
  Locally").
- Use screenshots, DOM inspection, and console checks to evaluate the result.
- Add or update tests only when an interaction contract stabilises.
- Do not add brittle tests for colours, spacing, shadows, borders, exact control
  ordering, right-or-left alignment, or general visual taste.

Behaviour changes still need the normal test discipline. Examples include mode
selection changing editor state, toolbar commands modifying Markdown, generated
assets being served, explicit Save submitting content to the server, and editor
content being preserved across view changes.

## Running the App Locally

The launch configurations live in `.claude/launch.json`.

- `verso` — the app on port 8080, via `make run-verso`.
- `verso-search-demo` — the same app on port 8081 against the search demo
  corpus (`MICROHTTP_CONFIG=build/search-demo.conf`). Prefer this one.
- `mockups` — a static server for `docs/mockups` on port 8123.

Port 8080 is frequently a developer's own running instance. Do not take it, and
do not kill whatever holds it, without asking first. Use `verso-search-demo` on
8081 instead.

Two documents in the demo corpus are worth knowing about for UI work.

- `guides/failover.md` — short, three headings. Use it for visual checks.
- `hangrepro890691783997417pub.md` — roughly 46,000px tall. Use it for anything
  that depends on document length, and expect screenshot tooling to struggle
  with a page that size.

## Generated CSS

The Moebius theme's watercolour wash — the four base-colour gradient tokens and
the layered backgrounds on the rail, top bar, content and command toolbar — is
generated, not hand-written. `bun run moebius` in `packages/verso-editor` rebuilds it in place; the same
check (part of that package's `bun run check`) fails if
`packages/verso/static/editor/markdown-editor.css` has drifted from what the
generator would write. Edit that CSS by hand and the next run reverts it silently. The numbers
are tuned in `docs/mockups/markdown-editor-moebius-watercolour-prototype.html`
and then carried into `packages/verso-editor/moebius/`.

## Running the Project Checks

`make check` runs, in order: the docs build, the format check, the linters, the
Haskell unit and integration suites, the editor checks (lint, typecheck and
Vitest), the Playwright editor smoke, and the chrome gates. It rebuilds the
editor bundle and the `verso` binary along the way, so it takes several minutes.

```bash
make check
```

A preview left running does not collide with the smoke. The smoke claims the
first free port from 8125 upwards and names its scratch tree, operation log and
config after whichever port it took, so a manual run and a `make check` can
proceed side by side (`packages/verso-editor/editor-smoke.cjs`).

## Editor Toolchain

The editor package (`packages/verso-editor`) has its own `bun install`, separate
from the root install that serves the documentation tooling. On a fresh checkout,
run `bun install` in both, and `bun x playwright install chromium` inside the
editor package for the smoke.

The editor's dependency versions are pinned deliberately, including an `overrides`
block that holds the whole `@tiptap`/`prosemirror` tree at a known-good version.
Do not upgrade them as a side effect of an install: a newer Tiptap changed the
Bold command the browser smoke checks. Treat editor installs as reproduce, not
upgrade.

## Documentation

`docs/README.md` maps what each `docs/` directory holds and where a new document
goes; read it before adding one. The ADR and RFC indexes are generated, so after
adding or editing a record run `bun run adr:index` or `bun run rfc:index` (`make
check` fails when they are stale). Every configuration key is catalogued in
`docs/reference/configuration.md`.
