# Agent Instructions

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
generated, not hand-written. `bun scripts/moebius/port.ts` rebuilds it in place;
`bun run editor:moebius` (part of `editor:check`) fails if
`static/editor/markdown-editor.css` has drifted from what the generator would
write. Edit that CSS by hand and the next run reverts it silently. The numbers
are tuned in `docs/mockups/markdown-editor-moebius-watercolour-prototype.html`
and then carried into `scripts/moebius/`.

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
proceed side by side (`scripts/editor-smoke.cjs`).
