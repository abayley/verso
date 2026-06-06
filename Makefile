MHS = mhs
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.0.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
BUILD = build
SPIKE = spike
SRC = src
TEST = test
UNIT_TEST = $(TEST)/unit
INTEGRATION_TEST = $(TEST)/integration
DOCS = docs
DOC_FILES = README.md INSTALL.md STANDARDS.md TODO.md "$(DOCS)/**/*.md"
HS_FILES = $(shell find $(SRC) $(TEST) -name '*.hs' | sort)

.PHONY: docs format format-check lint run-test-app test-unit test-integration test spike1 spike2 spike3 spike4 spike5 spike6 spike7 spike8 spike9 all-spikes check clean

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

test-unit:
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(UNIT_TEST) $(UNIT_TEST)/Main.hs -o $(BUILD)/unit-test
	$(BUILD)/unit-test

test-integration:
	mkdir -p $(BUILD)
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(INTEGRATION_TEST) $(INTEGRATION_TEST)/Main.hs -o $(BUILD)/integration-test
	$(BUILD)/integration-test

test: test-unit test-integration

check: docs format-check lint test

clean:
	rm -rf $(BUILD)
