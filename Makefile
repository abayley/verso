MHS = mhs
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.0.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
GHC = ghc
HPC = hpc
BUILD = build
SPIKE = spike
SRC = src
TEST = test
UNIT_TEST = $(TEST)/unit
INTEGRATION_TEST = $(TEST)/integration
GHC_COMPAT_TEST = $(TEST)/ghc-compat
DOCS = docs
DOC_FILES = README.md INSTALL.md STANDARDS.md TODO.md "$(DOCS)/**/*.md"
HS_FILES = $(shell find $(SRC) $(TEST) -name '*.hs' | sort)

.PHONY: docs format format-check lint run-test-app test-editor-browser test-unit test-integration test coverage coverage-unit coverage-integration spike-remark-ast spike1 spike2 spike3 spike4 spike5 spike6 spike7 spike8 spike9 all-spikes check clean

spike1:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike1.hs -o $(BUILD)/spike1

spike2:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike2.hs -o $(BUILD)/spike2

spike3:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike3.hs -o $(BUILD)/spike3

spike4:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike4.hs -o $(BUILD)/spike4

spike5:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike5.hs -o $(BUILD)/spike5

spike6:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike6.hs -o $(BUILD)/spike6

spike7:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike7.hs -o $(BUILD)/spike7

spike8:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike8.hs -o $(BUILD)/spike8

spike9:
	mkdir -p $(BUILD)
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike9.hs -o $(BUILD)/spike9

all-spikes: spike1 spike2 spike3 spike4 spike5 spike6 spike7 spike8 spike9

docs:
	markdownlint-cli2 $(DOC_FILES)

format:
	fourmolu --mode inplace $(HS_FILES)

format-check:
	fourmolu --mode check $(HS_FILES)

lint:
	hlint $(SRC) $(TEST)

run-test-app:
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -i$(SRC) $(SRC)/TestApp.hs -o $(BUILD)/test-app
	$(BUILD)/test-app

test-editor-browser:
	npx --yes --package=playwright -- sh -c 'NODE_PATH="$$(dirname "$$(dirname "$$(command -v playwright)")")" node scripts/editor-smoke.cjs'

test-unit:
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(UNIT_TEST) $(UNIT_TEST)/Main.hs -o $(BUILD)/unit-test
	$(BUILD)/unit-test

test-integration:
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(INTEGRATION_TEST) $(INTEGRATION_TEST)/Main.hs -o $(BUILD)/integration-test
	$(BUILD)/integration-test

test: test-unit test-integration

coverage-unit:
	rm -rf $(BUILD)/coverage/unit
	mkdir -p $(BUILD)/coverage/unit/mix $(BUILD)/coverage/unit/objects $(BUILD)/coverage/unit/report
	$(GHC) -fhpc -hpcdir $(BUILD)/coverage/unit/mix -XCApiFFI -XScopedTypeVariables -i$(GHC_COMPAT_TEST) -i$(SRC) -i$(UNIT_TEST) $(UNIT_TEST)/Main.hs -outputdir $(BUILD)/coverage/unit/objects -o $(BUILD)/coverage/unit/unit-test
	HPCTIXFILE=$(BUILD)/coverage/unit/unit-test.tix $(BUILD)/coverage/unit/unit-test
	$(HPC) report $(BUILD)/coverage/unit/unit-test.tix --hpcdir $(BUILD)/coverage/unit/mix --per-module
	$(HPC) markup $(BUILD)/coverage/unit/unit-test.tix --hpcdir $(BUILD)/coverage/unit/mix --destdir $(BUILD)/coverage/unit/report

coverage-integration:
	rm -rf $(BUILD)/coverage/integration
	mkdir -p $(BUILD)/coverage/integration/mix $(BUILD)/coverage/integration/objects $(BUILD)/coverage/integration/report
	$(GHC) -fhpc -hpcdir $(BUILD)/coverage/integration/mix -XCApiFFI -XScopedTypeVariables -i$(GHC_COMPAT_TEST) -i$(SRC) -i$(INTEGRATION_TEST) $(INTEGRATION_TEST)/Main.hs -outputdir $(BUILD)/coverage/integration/objects -o $(BUILD)/coverage/integration/integration-test
	HPCTIXFILE=$(BUILD)/coverage/integration/integration-test.tix $(BUILD)/coverage/integration/integration-test
	$(HPC) report $(BUILD)/coverage/integration/integration-test.tix --hpcdir $(BUILD)/coverage/integration/mix --per-module
	$(HPC) markup $(BUILD)/coverage/integration/integration-test.tix --hpcdir $(BUILD)/coverage/integration/mix --destdir $(BUILD)/coverage/integration/report

coverage: coverage-unit coverage-integration

spike-remark-ast:
	mkdir -p $(BUILD)/remark-spike-deps
	npm install --silent --no-save --prefix $(BUILD)/remark-spike-deps unified remark-parse remark-stringify remark-gfm remark-rehype rehype-stringify
	node scripts/remark-ast-spike.mjs

check: docs format-check lint test

clean:
	rm -rf $(BUILD)
