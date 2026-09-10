MHS = mhs
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.5.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
# The MicroHs heap is a fixed, non-growable arena of this many 16-byte cells,
# allocated once at process start (its default, 50,000,000 cells, is ~763MB and
# becomes resident under the link-index build's allocation churn). run-verso
# passes it as +RTS -H<cells>; 16M cells (~256MB) holds the real corpus with
# headroom. Raise it if the server ever dies with "heap exhausted" under load;
# lower it to trade a smaller footprint for more frequent GC. Override on the
# command line: `make run-verso VERSO_HEAP_CELLS=24000000`.
VERSO_HEAP_CELLS ?= 16000000
GHC = ghc
HPC = hpc
BUILD = build
BENCH = test/bench
EDITOR = packages/verso-editor
# The framework is a MicroCabal package (RFC-0038): its modules and its cbits are
# installed into the package database, and the Verso build resolves them from there
# via -a$(MHS_PACKAGE_DB), the same way base and mtl resolve.
MICROHTTP = packages/micro-http
MICROHTTP_SRC = $(MICROHTTP)/src
MICROHTTP_HS = $(shell find $(MICROHTTP_SRC) -name '*.hs' | sort)
MICROHTTP_CBITS = $(MICROHTTP)/cbits
MICROHTTP_INCLUDE = $(MICROHTTP)/include
MICROHTTP_PKG = $(MHS_PACKAGE_DB)/packages/micro-http-0.1.0.0.pkg
# The Verso application (Verso.* and Concordance.*), its Concordance cbits, and its
# served static assets live in the verso package (RFC-0038). SRC is that package's
# Haskell source root; the framework it depends on is the micro-http package above.
VERSO = packages/verso
SRC = $(VERSO)/src
STATIC = $(VERSO)/static
TEST = test
UNIT_TEST = $(TEST)/unit
INTEGRATION_TEST = $(TEST)/integration
GHC_COMPAT_TEST = $(TEST)/ghc-compat
DOCS = docs
DOC_FILES = README.md INSTALL.md STANDARDS.md TODO.md AGENTS.md CLAUDE.md "$(DOCS)/**/*.md"
# Benchmarks under $(BENCH) are measurement code, deliberately outside the
# format and lint gate (as they were when they lived in a top-level bench/).
HS_FILES = $(shell find $(SRC) $(MICROHTTP_SRC) $(TEST) -name '*.hs' -not -path '$(BENCH)/*' | sort)

# Prerequisites for the mhs binaries. mhs is a whole-program compiler, so every
# binary depends on the whole of src/; the test binaries add their own tree. These
# exist so `make check` stops recompiling all three unconditionally -- that was 57
# of its 122 seconds, and none of it was needed when nothing had changed.
SRC_HS = $(shell find $(SRC) -name '*.hs' | sort)
UNIT_HS = $(shell find $(UNIT_TEST) -name '*.hs' | sort)
INTEGRATION_HS = $(shell find $(INTEGRATION_TEST) -name '*.hs' | sort)

# --- Concordance search shim (RFC-0034) ---------------------------------
# The Haskell code has foreign imports of cn_* symbols, so every mhs link
# needs an implementation. `make search-shim` builds the real one (ONNX
# Runtime + patched lancedb-c dylib + nanoarrow); otherwise a no-dependency
# stub is linked and search reports itself unavailable at runtime.
CBITS = $(VERSO)/cbits
SEARCH_BUILD = $(BUILD)/search
VENDOR_SEARCH = vendor/search
SEARCH_PLATFORM := $(shell uname -s | tr A-Z a-z)-$(shell uname -m)
SEARCH_LIB_DIR = $(VENDOR_SEARCH)/$(SEARCH_PLATFORM)
ORT_PREFIX := $(shell brew --prefix onnxruntime 2>/dev/null)
SEARCH_REAL := $(wildcard $(SEARCH_BUILD)/concordance_shim.o)
ifneq ($(SEARCH_REAL),)
SEARCH_OBJS = $(SEARCH_BUILD)/concordance_shim.o $(SEARCH_BUILD)/nanoarrow.o
SEARCH_LINK = $(foreach o,$(SEARCH_OBJS),-optl $(o)) \
    -optl -L$(SEARCH_LIB_DIR) -optl -llancedb \
    -optl -L$(ORT_PREFIX)/lib -optl -lonnxruntime \
    -optl -Wl,-rpath,$(abspath $(SEARCH_LIB_DIR)) \
    -optl -Wl,-rpath,$(ORT_PREFIX)/lib
# The same libraries in GHC's flag spelling, for the coverage builds.
SEARCH_GHC_LINK = $(SEARCH_OBJS) \
    -L$(SEARCH_LIB_DIR) -llancedb \
    -L$(ORT_PREFIX)/lib -lonnxruntime \
    -optl-Wl,-rpath,$(abspath $(SEARCH_LIB_DIR)) \
    -optl-Wl,-rpath,$(ORT_PREFIX)/lib
SEARCH_DEP =
else
SEARCH_OBJS = $(SEARCH_BUILD)/concordance_stub.o
SEARCH_LINK = -optl $(SEARCH_BUILD)/concordance_stub.o
SEARCH_GHC_LINK = $(SEARCH_OBJS)
SEARCH_DEP = $(SEARCH_BUILD)/concordance_stub.o
endif
# The filesystem syscall wrappers (MicroHttp.FileSystem), the HTML escaper
# (MicroHttp.Html) and the posix_spawn wrapper (MicroHttp.Process) live in the micro-http package: the mhs builds
# link them from there automatically. These objects are still built for the GHC
# coverage builds, which compile every source directly and do not use the package.
FS_OBJ = $(BUILD)/microhttp_fs.o
HTML_OBJ = $(BUILD)/microhttp_html.o
PROC_OBJ = $(BUILD)/microhttp_process.o
CBITS_OBJS = $(FS_OBJ) $(HTML_OBJ) $(PROC_OBJ)
# The mhs search flags carry only the Concordance shim/stub (Concordance stays in
# the Verso build); the micro-http cbits arrive with the package.
MHS_SEARCH = -optc -I$(CBITS) $(SEARCH_LINK)
LINK_OBJS = $(SEARCH_DEP) $(wildcard $(SEARCH_OBJS))

# Install (or reinstall) the framework package when its sources change, so the
# Verso and test binaries resolve the current MicroHttp modules and cbits.
$(MICROHTTP_PKG): $(MICROHTTP_HS) $(MICROHTTP_CBITS)/microhttp_fs.c $(MICROHTTP_CBITS)/microhttp_html.c $(MICROHTTP_CBITS)/microhttp_process.c $(MICROHTTP_INCLUDE)/microhttp_fs.h $(MICROHTTP_INCLUDE)/microhttp_html.h $(MICROHTTP_INCLUDE)/microhttp_process.h $(MICROHTTP)/micro-http.cabal
	cd $(MICROHTTP) && mcabal install

$(SEARCH_BUILD)/concordance_stub.o: $(CBITS)/concordance_stub.c $(CBITS)/concordance_shim.h
	mkdir -p $(SEARCH_BUILD)
	cc -O2 -Wall -c $< -o $@ -I$(CBITS)

$(FS_OBJ): $(MICROHTTP_CBITS)/microhttp_fs.c $(MICROHTTP_INCLUDE)/microhttp_fs.h
	mkdir -p $(BUILD)
	cc -O2 -Wall -c $< -o $@ -I$(MICROHTTP_INCLUDE)

$(HTML_OBJ): $(MICROHTTP_CBITS)/microhttp_html.c $(MICROHTTP_INCLUDE)/microhttp_html.h
	mkdir -p $(BUILD)
	cc -O2 -Wall -c $< -o $@ -I$(MICROHTTP_INCLUDE)

$(PROC_OBJ): $(MICROHTTP_CBITS)/microhttp_process.c $(MICROHTTP_INCLUDE)/microhttp_process.h
	mkdir -p $(BUILD)
	cc -O2 -Wall -c $< -o $@ -I$(MICROHTTP_INCLUDE)

.PHONY: chrome-gates docs editor-build editor-check editor-format editor-knip editor-lint editor-test editor-typecheck format format-check lint run-verso replay-tool test-editor-browser test-unit test-integration test coverage coverage-unit coverage-integration bench-form-decode bench-socket bench-socket-saturated bench-iteratee bench-egress bench-http bench-html-builder bench-link-parse bench-search-chunk search-lancedb search-nanoarrow search-model search-shim check clean


docs:
	markdownlint-cli2 $(DOC_FILES)
	bun run docs:typecheck
	bun run check:adr-index
	bun run check:rfc-index

editor-build:
	cd $(EDITOR) && bun run build

editor-format:
	cd $(EDITOR) && bun run format

editor-lint:
	cd $(EDITOR) && bun run lint

editor-knip:
	cd $(EDITOR) && bun run knip

editor-test:
	cd $(EDITOR) && bun run test

editor-typecheck:
	cd $(EDITOR) && bun run typecheck

editor-check: editor-lint editor-typecheck editor-test editor-build

format:
	fourmolu --mode inplace $(HS_FILES)

format-check:
	fourmolu --mode check $(HS_FILES)

lint:
	# -j0 uses every core: 11.8s single-threaded against 2.7s here, measured on 12 cores.
	# $(BENCH) is excluded to match the format gate: benchmarks are measurement code.
	hlint -j0 $(SRC) $(MICROHTTP_SRC) $(UNIT_TEST) $(INTEGRATION_TEST) $(GHC_COMPAT_TEST)

$(BUILD)/verso: $(SRC_HS) $(MICROHTTP_PKG) $(LINK_OBJS)
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) $(MHS_SEARCH) -i$(SRC) $(SRC)/Verso/Main.hs -o $@

run-verso: editor-build $(BUILD)/verso
	$(BUILD)/verso +RTS -H$(VERSO_HEAP_CELLS) -RTS

# Replay the operation log onto the tree (RFC-0028), after a corpus refresh. Reads
# the same config as the server (MICROHTTP_CONFIG, default micro-http.conf).
replay-tool: $(SEARCH_DEP) $(MICROHTTP_PKG)
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) $(MHS_SEARCH) -i$(SRC) $(SRC)/Verso/ReplayTool.hs -o $(BUILD)/replay-tool
	$(BUILD)/replay-tool

test-editor-browser: editor-build $(BUILD)/verso
	bun $(EDITOR)/editor-smoke.cjs

$(BUILD)/unit-test: $(SRC_HS) $(UNIT_HS) $(MICROHTTP_PKG) $(LINK_OBJS)
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) $(MHS_SEARCH) -i$(SRC) -i$(UNIT_TEST) $(UNIT_TEST)/Main.hs -o $@

test-unit: $(BUILD)/unit-test
	$(BUILD)/unit-test

$(BUILD)/integration-test: $(SRC_HS) $(INTEGRATION_HS) $(MICROHTTP_PKG) $(LINK_OBJS)
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) $(MHS_SEARCH) -i$(SRC) -i$(INTEGRATION_TEST) $(INTEGRATION_TEST)/Main.hs -o $@

test-integration: $(BUILD)/integration-test
	$(BUILD)/integration-test

test: test-unit test-integration

coverage-unit: $(SEARCH_DEP)
	rm -rf $(BUILD)/coverage/unit
	mkdir -p $(BUILD)/coverage/unit/mix $(BUILD)/coverage/unit/objects $(BUILD)/coverage/unit/report
	$(GHC) -threaded -fhpc -hpcdir $(BUILD)/coverage/unit/mix $(SEARCH_GHC_LINK) $(CBITS_OBJS) -I$(MICROHTTP_INCLUDE) -I$(CBITS) -XCApiFFI -XScopedTypeVariables -i$(GHC_COMPAT_TEST) -i$(SRC) -i$(MICROHTTP_SRC) -i$(UNIT_TEST) $(UNIT_TEST)/Main.hs -outputdir $(BUILD)/coverage/unit/objects -o $(BUILD)/coverage/unit/unit-test
	HPCTIXFILE=$(BUILD)/coverage/unit/unit-test.tix $(BUILD)/coverage/unit/unit-test
	$(HPC) report $(BUILD)/coverage/unit/unit-test.tix --hpcdir $(BUILD)/coverage/unit/mix --per-module
	$(HPC) markup $(BUILD)/coverage/unit/unit-test.tix --hpcdir $(BUILD)/coverage/unit/mix --destdir $(BUILD)/coverage/unit/report

coverage-integration: $(SEARCH_DEP)
	rm -rf $(BUILD)/coverage/integration
	mkdir -p $(BUILD)/coverage/integration/mix $(BUILD)/coverage/integration/objects $(BUILD)/coverage/integration/report
	$(GHC) -threaded -fhpc -hpcdir $(BUILD)/coverage/integration/mix $(SEARCH_GHC_LINK) $(CBITS_OBJS) -I$(MICROHTTP_INCLUDE) -I$(CBITS) -XCApiFFI -XScopedTypeVariables -i$(GHC_COMPAT_TEST) -i$(SRC) -i$(MICROHTTP_SRC) -i$(INTEGRATION_TEST) $(INTEGRATION_TEST)/Main.hs -outputdir $(BUILD)/coverage/integration/objects -o $(BUILD)/coverage/integration/integration-test
	HPCTIXFILE=$(BUILD)/coverage/integration/integration-test.tix $(BUILD)/coverage/integration/integration-test
	$(HPC) report $(BUILD)/coverage/integration/integration-test.tix --hpcdir $(BUILD)/coverage/integration/mix --per-module
	$(HPC) markup $(BUILD)/coverage/integration/integration-test.tix --hpcdir $(BUILD)/coverage/integration/mix --destdir $(BUILD)/coverage/integration/report

coverage: coverage-unit coverage-integration

# Measurement spike: Haskell vs C for the form-decode per-byte pass.
bench-form-decode: $(CBITS_OBJS)
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -optc -I$(CBITS) $(foreach o,$(CBITS_OBJS),-optl $(o)) -i$(SRC) -i$(BENCH) $(BENCH)/FormDecodeBench.hs -o $(BUILD)/form-decode-bench
	$(BUILD)/form-decode-bench

bench-socket: $(FS_OBJ)
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -optc -I$(CBITS) -optl $(FS_OBJ) -i$(SRC) -i$(BENCH) $(BENCH)/SocketBench.hs -o $(BUILD)/socket-bench
	$(BUILD)/socket-bench

bench-socket-saturated:
	MHS_PACKAGE_DB=$(MHS_PACKAGE_DB) bash $(BENCH)/socket-saturated-bench.sh

bench-html-builder:
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(BENCH) $(BENCH)/HtmlBuilderBench.hs -o $(BUILD)/html-builder-bench
	$(BUILD)/html-builder-bench

bench-link-parse:
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(BENCH) $(BENCH)/LinkParseBench.hs -o $(BUILD)/link-parse-bench
	$(BUILD)/link-parse-bench

bench-search-chunk:
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(BENCH) $(BENCH)/SearchChunkBench.hs -o $(BUILD)/search-chunk-bench
	$(BUILD)/search-chunk-bench

bench-iteratee:
	MHS_PACKAGE_DB=$(MHS_PACKAGE_DB) bash $(BENCH)/iteratee-bench.sh

bench-egress:
	MHS_PACKAGE_DB=$(MHS_PACKAGE_DB) bash $(BENCH)/egress-bench.sh

bench-http:
	MHS_PACKAGE_DB=$(MHS_PACKAGE_DB) bash $(BENCH)/http-bench.sh

# --- Concordance search build targets (RFC-0034; all optional) ----------
# search-lancedb: build the patched lancedb-c dylib (needs Rust + the
#   upstream clone; run once per platform, cached under vendor/).
# search-nanoarrow: fetch and bundle the nanoarrow amalgamation.
# search-model: download the embedding model + vocab (checksum-pinned).
# search-shim: compile the real shim (needs onnxruntime via Homebrew and
#   the two targets above); after this, mhs targets link the real shim.
SEARCH_MODEL_DIR = $(SEARCH_LIB_DIR)/model
SEARCH_MODEL_URL = https://huggingface.co/Xenova/bge-small-en-v1.5/resolve/main
SEARCH_MODEL_SHA = 6c9c6101a956d62dfb5e7190c538226c0c5bb9cb27b651234b6df063ee7dbfe4
SEARCH_VOCAB_SHA = 07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3
LANCEDB_C_REPO = https://github.com/lancedb/lancedb-c.git
NANOARROW_URL = https://github.com/apache/arrow-nanoarrow/releases/download/apache-arrow-nanoarrow-0.8.0/apache-arrow-nanoarrow-0.8.0.tar.gz

search-lancedb:
	mkdir -p $(SEARCH_LIB_DIR)
	test -d $(VENDOR_SEARCH)/lancedb-c || \
	    (git clone --depth 1 $(LANCEDB_C_REPO) $(VENDOR_SEARCH)/lancedb-c && \
	     cd $(VENDOR_SEARCH)/lancedb-c && git apply ../../../spike/search/lancedb-c-fts-query.patch)
	cd $(VENDOR_SEARCH)/lancedb-c && cargo build --release
	cp $(VENDOR_SEARCH)/lancedb-c/target/release/liblancedb.dylib $(SEARCH_LIB_DIR)/ 2>/dev/null || \
	    cp $(VENDOR_SEARCH)/lancedb-c/target/release/liblancedb.so $(SEARCH_LIB_DIR)/

search-nanoarrow:
	test -d $(VENDOR_SEARCH)/nanoarrow-bundle || \
	    (mkdir -p $(VENDOR_SEARCH) && cd $(VENDOR_SEARCH) && \
	     curl -sfL $(NANOARROW_URL) | tar xz && \
	     python3 apache-arrow-nanoarrow-0.8.0/ci/scripts/bundle.py \
	         --source-output-dir nanoarrow-bundle --include-output-dir nanoarrow-bundle)

search-model:
	mkdir -p $(SEARCH_MODEL_DIR)
	test -f $(SEARCH_MODEL_DIR)/model_quantized.onnx || \
	    curl -sfL $(SEARCH_MODEL_URL)/onnx/model_quantized.onnx -o $(SEARCH_MODEL_DIR)/model_quantized.onnx
	echo "$(SEARCH_MODEL_SHA)  $(SEARCH_MODEL_DIR)/model_quantized.onnx" | shasum -a 256 -c -
	test -f $(SEARCH_MODEL_DIR)/vocab.txt || \
	    curl -sfL $(SEARCH_MODEL_URL)/vocab.txt -o $(SEARCH_MODEL_DIR)/vocab.txt
	echo "$(SEARCH_VOCAB_SHA)  $(SEARCH_MODEL_DIR)/vocab.txt" | shasum -a 256 -c -

search-shim: search-nanoarrow
	mkdir -p $(SEARCH_BUILD)
	cc -O2 -Wall -c $(VENDOR_SEARCH)/nanoarrow-bundle/nanoarrow.c \
	    -o $(SEARCH_BUILD)/nanoarrow.o -I$(VENDOR_SEARCH)/nanoarrow-bundle
	cc -O2 -Wall -c $(CBITS)/concordance_shim.c -o $(SEARCH_BUILD)/concordance_shim.o \
	    -I$(CBITS) -I"$(ORT_PREFIX)/include" -I$(VENDOR_SEARCH)/nanoarrow-bundle \
	    -I$(VENDOR_SEARCH)/lancedb-c/include
	@echo "search shim built; mhs targets now link the real shim"

# RFC-0035 presentation-isolation gates: the Basecoat variant vocabulary lives
# only in the chrome helper pair; App.hs constructs no markup (views live in
# Verso.View/Verso.Chrome); no Web Awesome remains anywhere in src/.
chrome-gates:
	@if grep -rn 'data-variant' $(SRC) $(EDITOR)/src --include='*.hs' --include='*.ts' | grep -v '$(SRC)/Verso/Chrome.hs:\|$(EDITOR)/src/chrome.ts:'; then echo "chrome-gates FAILED: data-variant outside the chrome modules"; exit 1; fi
	@if grep -nE 'Html\.(el|custom|div|button_?|input|attr|class_|form_|span|nav|section|header) ' $(SRC)/Verso/App.hs; then echo "chrome-gates FAILED: markup construction in App.hs"; exit 1; fi
	@if grep -rn 'wa-' $(SRC) $(EDITOR)/src --include='*.hs' --include='*.ts'; then echo "chrome-gates FAILED: Web Awesome reference in src/"; exit 1; fi
	@dead_classes=$$( \
		grep -oE '\.markdown-editor__[[:alnum:]_-]+' $(STATIC)/editor/markdown-editor.css \
		| cut -c 2- \
		| sort -u \
		| while IFS= read -r class_name; do \
			if ! grep -rFq "$$class_name" $(SRC) $(EDITOR)/src --include='*.hs' --include='*.ts'; then echo "$$class_name"; fi; \
		done \
	); \
		if [ -n "$$dead_classes" ]; then echo "chrome-gates FAILED: CSS classes without a source producer:"; echo "$$dead_classes"; exit 1; fi
	@echo "chrome-gates OK"

check: docs format-check lint test editor-check test-editor-browser chrome-gates

clean:
	rm -rf $(BUILD)
	rm -f $(STATIC)/editor/markdown-editor.js
