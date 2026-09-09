# RFC-0038 Build Coupling Inventory (2026-09-09)

Supporting material for [RFC-0038](../rfc-0038-repository-package-structure.md). A point-in-time inventory
of every place the build configuration hardcodes a directory path that a move under RFC-0038 would touch.
Paths are repo-relative. Line numbers are as of HEAD on 2026-09-09 and will drift; treat them as pointers.

The single most load-bearing runtime coupling is `src/Verso/App.hs:295`
(`Static.static "/static/editor" "static/editor"`): the built-in mount defaults both the URL prefix and the
served directory to `static/editor`, and `micro-http.conf` relies on it (no `static_mounts` line). Every
`View.hs` / `Chrome.hs` / `mermaid-loader.ts` URL and the smoke and http-bench configs assume that
`/static/editor` prefix. The TypeScript-package move and the `static/` move meet here and in
`scripts/build-editor.mjs`, which reads entrypoints from `src/Verso/Editor/` and writes bundles into
`static/editor/`.

## A. Makefile

Directory variables (lines 6-24): `BUILD = build`, `SPIKE = spike`, `BENCH = bench`, `SRC = src`,
`TEST = test`, `UNIT_TEST = $(TEST)/unit`, `INTEGRATION_TEST = $(TEST)/integration`,
`GHC_COMPAT_TEST = $(TEST)/ghc-compat`, `DOCS = docs`, and the `find`-based `HS_FILES` (16), `SRC_HS` (22),
`UNIT_HS` (23), `INTEGRATION_HS` (24).

Search-shim and cbits object paths (lines 31-78):

- `CBITS = cbits` (31); `SEARCH_BUILD = $(BUILD)/search` (32); `VENDOR_SEARCH = vendor/search` (33);
  `SEARCH_LIB_DIR = $(VENDOR_SEARCH)/$(SEARCH_PLATFORM)` (35).
- `SEARCH_LINK` (40-44) embeds `-optl <obj>`, `-optl -L$(SEARCH_LIB_DIR)`, and an rpath of
  `$(abspath $(SEARCH_LIB_DIR))`; `SEARCH_GHC_LINK` (46-50) is the GHC spelling of the same lib dirs.
- Object paths: `$(SEARCH_BUILD)/concordance_shim.o` and `nanoarrow.o` (37, 39), stub branch
  `$(SEARCH_BUILD)/concordance_stub.o` (53-56), `FS_OBJ = $(BUILD)/microhttp_fs.o` (61),
  `PROC_OBJ = $(BUILD)/microhttp_process.o` (62), `CBITS_OBJS` (63).
- `MHS_SEARCH = -optc -I$(CBITS) $(SEARCH_LINK) -optl <cbits objs>` (64).
- `cc` rules: stub (68-70), `FS_OBJ` (72-74), `PROC_OBJ` (76-78), each `-I$(CBITS)` over a `cbits/*.c`.

Spike targets (82-124): `spike1`..`spike11`, each `-i$(SPIKE) $(SPIKE)/MicroHttp/SpikeN.hs -o $(BUILD)/spikeN`.

Lint/format: fourmolu over `$(HS_FILES)` (155, 158); `hlint -j0 $(SRC) $(TEST)` (162).

Main binaries: `$(BUILD)/verso` from `-i$(SRC) $(SRC)/Verso/Main.hs` (164-166); `run-verso` (168-169);
`replay-tool` from `-i$(SRC) $(SRC)/Verso/ReplayTool.hs` (173-176); `test-editor-browser` runs
`bun scripts/editor-smoke.cjs` (178-179); `$(BUILD)/unit-test` from `-i$(SRC) -i$(UNIT_TEST)` (181-183) and
run (185-186); `$(BUILD)/integration-test` from `-i$(SRC) -i$(INTEGRATION_TEST)` (188-190) and run (192-193).

Coverage (GHC): `coverage-unit` (197-203) uses `$(BUILD)/coverage/unit/{mix,objects,report}` and
`-i$(GHC_COMPAT_TEST) -i$(SRC) -i$(UNIT_TEST)` plus `$(SEARCH_GHC_LINK) $(CBITS_OBJS)`; `coverage-integration`
(205-211) is the same over the integration tree.

Bench targets (216-254): `bench-form-decode`, `bench-socket`, `bench-html-builder`, `bench-link-parse`,
`bench-search-chunk` each `-i$(SRC) -i$(BENCH) $(BENCH)/<X>Bench.hs -o $(BUILD)/<x>-bench` (some add
`-optc -I$(CBITS)` and cbits objs); `bench-socket-saturated`, `bench-iteratee`, `bench-egress`, `bench-http`
shell out to `scripts/*.sh`; `spike-remark-ast` runs `bun scripts/remark-ast-spike.mjs`.

Search build targets (263-302): `SEARCH_MODEL_DIR = $(SEARCH_LIB_DIR)/model` (263); `search-lancedb`
(`$(VENDOR_SEARCH)/lancedb-c`, patch `spike/search/lancedb-c-fts-query.patch`) (270-277); `search-nanoarrow`
(`$(VENDOR_SEARCH)/nanoarrow-bundle`) (279-284); `search-model` (286-293); `search-shim` (295-302) compiles
`$(VENDOR_SEARCH)/nanoarrow-bundle/nanoarrow.c` and `$(CBITS)/concordance_shim.c` with
`-I$(CBITS) -I"$(ORT_PREFIX)/include" -I$(VENDOR_SEARCH)/nanoarrow-bundle -I$(VENDOR_SEARCH)/lancedb-c/include`.

`chrome-gates` (308-316): greps `src`, whitelists `src/Verso/Chrome.hs` and `src/Verso/Editor/chrome.ts`,
names `src/Verso/App.hs`, and checks `static/editor/markdown-editor.css` (312).

`check` (322) aggregates the phases; `clean` (324-326) does `rm -rf $(BUILD)` and
`rm -f static/editor/markdown-editor.js`.

## B. TypeScript toolchain

`package.json` scripts: `docs:typecheck` -> `-p scripts/tsconfig.json` (9); `editor:build` ->
`bun scripts/build-editor.mjs` (10); `editor:format`/`editor:lint` -> `biome check ... src/Verso/Editor
test/editor scripts/moebius package.json tsconfig.json biome.json knip.json vitest.config.ts` (12, 14);
`editor:moebius` -> `bun scripts/moebius/port.ts --check` (15); `editor:typecheck` ->
`tsc --noEmit && tsc --noEmit -p scripts/moebius` (17).

`biome.json`: no path globs (targeted via the CLI args above).

`knip.json`: entry (4-9) `src/Verso/Editor/index.ts`, `appearance-bootstrap.ts`, `mermaid-entry.ts`,
`scripts/editor-smoke.cjs`, `scripts/remark-ast-spike.mjs`, `test/editor/**/*.test.ts`; project (11-16)
`src/Verso/Editor/**/*.ts`, `test/editor/**/*.ts`, `scripts/moebius/**/*.ts`, `scripts/*.cjs`, `scripts/*.mjs`.

`tsconfig.json` include (38): `src/Verso/Editor/**/*.ts`, `test/editor/**/*.ts`. `scripts/tsconfig.json`
include (20): `generate-adr-index.ts`, `generate-rfc-index.ts`, `lib/**/*.ts`. `scripts/moebius/tsconfig.json`
extends `../../tsconfig.json` (2), include `**/*.ts` (9). `vitest.config.ts` setupFiles `test/editor/setup.ts`
(6).

`scripts/build-editor.mjs` (entrypoints in `src/Verso/Editor/`, all outputs under `static/editor/`): imports
`../src/Verso/Editor/editor-layout.ts` (1) and `visual-theme-registry.ts` (2); outfiles
`markdown-editor.js` (4), `appearance-bootstrap.js` (7), `mermaid.js` (10), `basecoat.css` (14),
`basecoat.js` (16), `roboto.css` (22), `roboto-mono.css` (23), font tree `static/editor/files` (25),
stylesheet ref `static/editor/markdown-editor.css` (26); entrypoints `src/Verso/Editor/index.ts` (48),
`appearance-bootstrap.ts` (50), `mermaid-entry.ts` (51).

`scripts/moebius/port.ts`: reads and rewrites `../../static/editor/markdown-editor.css` (22); imports
`./fade.ts`, `./wash.ts` (19). `fade.ts:5` and `wash.ts:5` name
`docs/mockups/markdown-editor-moebius-watercolour-prototype.html`; `port.ts:243` names
`docs/reviews/drawn-frames-paint-profile.md` (moved this session).

`scripts/editor-smoke.cjs`: `build/smoke-tree` (18), `build/smoke-ops` (19), `build/smoke.conf` (20), the
port-suffixed variants (29-31), `spawn("./build/verso")` (777), served refs
`/static/editor/markdown-editor.css` (912) and `markdown-editor.js` (913), and the generated config line
`static_mounts = /static/editor static/editor` (1040).

## C. static/ references

Haskell: `src/Verso/App.hs:144` config-driven mounts; `App.hs:295` the hardcoded default
`Static.static "/static/editor" "static/editor"`; `src/Verso/View.hs` URLs at 49-53, 75, 78, 427, 430
(`roboto.css`, `roboto-mono.css`, `basecoat.css`, `markdown-editor.css`, `basecoat.js`,
`appearance-bootstrap.js`, `markdown-editor.js`); `src/Verso/Chrome.hs:76` `/static/editor/icons.svg#i-<name>`.

TypeScript: `src/Verso/Editor/mermaid-loader.ts:12` `MERMAID_SRC = "/static/editor/mermaid.js"`;
`mermaid-entry.ts:5` and `chrome.ts:89` comments; `test/editor/version-appearance.test.ts:86,97`
`/static/editor/icons.svg#i-sun` / `#i-moon`.

Config: `src/Verso/Config.hs:32` field `staticMounts`, `:66` key `"static_mounts"`, `:128` no default (so the
App.hs:295 built-in supplies it); `micro-http.conf.example:24`
`static_mounts = /static/editor static/editor`; `micro-http.conf` has no `static_mounts` line.

## D. cbits references

Makefile `-I$(CBITS)` at 64, 70, 74, 78, 300 and the object paths listed in section A. Sibling includes:
`cbits/microhttp_fs.c:7` `#include "microhttp_fs.h"`; `cbits/microhttp_process.c:5`
`#include "microhttp_process.h"`; `cbits/concordance_stub.c:7` `#include "concordance_shim.h"`;
`cbits/concordance_shim.c` includes `nanoarrow/nanoarrow.h` (19, vendor bundle), `<lancedb.h>` (21, vendor
include), and `concordance_shim.h` (22). The bench shell scripts also compile cbits directly (section F).

## E. .gitignore

`build/` (1), `static/editor/appearance-bootstrap.js` (6), `static/editor/markdown-editor.js` (7),
`static/editor/mermaid.js` (8), `static/editor/webawesome.css` (9), `spike/editor-studio/bundle.js` (11),
`spike/editor-lit/bundle.js` (12), `vendor/` (17), and the `spike/search/*` scratch entries (18-25). Also
`node_modules/` (2), `data/` (3), and `docs/mockups/images/` (13-14), which are outside the move set.

## F. Other hardcoded paths

The bench shell scripts each independently hardcode `$ROOT/src`, `$ROOT/bench`, `$ROOT/bench/sender`, and
`$ROOT/cbits` (they do not use the Makefile variables, so they need separate updating):

- `scripts/socket-saturated-bench.sh`: `BUILD` (9), `cc ... $ROOT/cbits/microhttp_fs.c ... -I$ROOT/cbits`
  (19), `mhs ... -i$ROOT/src -i$ROOT/bench $ROOT/bench/SocketReceiver.hs` (20), `$ROOT/bench/sender` (23-24).
- `scripts/iteratee-bench.sh`: `BUILD` (9), cbits compile (20), `mhs ... -i$ROOT/src -i$ROOT/bench
  $ROOT/bench/IterateeReceiver.hs` (21), `$ROOT/bench/sender` (24-25).
- `scripts/egress-bench.sh`: `BUILD` (10), cbits compile (20), `mhs ... $ROOT/bench/EgressSender.hs` (21),
  `$ROOT/bench/sender` (24-25).
- `scripts/http-bench.sh`: `BUILD` (12), cbits compiles for fs and stub (31-32), `mhs ... -i$ROOT/src
  $ROOT/src/Verso/Main.hs -o $BUILD/verso-bench` (33-34), snapshot `static/editor/_bench-snapshot.html` (38),
  conf `static_mounts` and `document_root = data/documents` (42), served bench paths under `/static/editor`
  (83-85).
- `scripts/hang-repro.sh`: `cd` to repo root then `build/search-demo/index`, `MICROHTTP_CONFIG=
  build/search-demo.conf`, runs `./build/verso`, greps stuck `build/verso` children.
- `scripts/remark-ast-spike.mjs`: `build/remark-spike-deps/package.json` (6), `build/remark-spike` (84),
  `build/remark-spike/report.json` (85, 87).

Config defaults co-located with the move set (`src/Verso/Config.hs`): `accessLog` default `build/access.log`
(124), `clientErrorLog` default `build/client-errors.log` (125), and the `data/*` index/log/trash defaults
(120-138); `micro-http.conf.example:20-21` names the two `build/` log paths.
