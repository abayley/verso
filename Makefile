MHS = ../MicroHs/bin/mhs
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.0.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
SPIKE = spike
SRC = src
TEST = test
UNIT_TEST = $(TEST)/unit
INTEGRATION_TEST = $(TEST)/integration
DOCS = docs
DOC_FILES = README.md INSTALL.md STANDARDS.md TODO.md "$(DOCS)/**/*.md"

.PHONY: docs test-unit test-integration test spike1 spike2 spike3 spike4 spike5 spike6 spike7 spike8 spike9 all-spikes check clean

spike1:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike1.hs -o spike1

spike2:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike2.hs -o spike2

spike3:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike3.hs -o spike3

spike4:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike4.hs -o spike4

spike5:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike5.hs -o spike5

spike6:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike6.hs -o spike6

spike7:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike7.hs -o spike7

spike8:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike8.hs -o spike8

spike9:
	$(MHS) -i$(SPIKE) $(SPIKE)/MicroHttp/Spike9.hs -o spike9

all-spikes: spike1 spike2 spike3 spike4 spike5 spike6 spike7 spike8 spike9

docs:
	markdownlint-cli2 $(DOC_FILES)

test-unit:
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(UNIT_TEST) $(UNIT_TEST)/Main.hs -o unit-test
	./unit-test

test-integration:
	$(MHS) $(MHSFLAGS) -i$(SRC) -i$(INTEGRATION_TEST) $(INTEGRATION_TEST)/Main.hs -o integration-test
	./integration-test

test: test-unit test-integration

check: docs test all-spikes

clean:
	rm -f unit-test integration-test facade-test html-test http-test parser-test response-test router-test server-test socket-test spike1 spike2 spike3 spike4 spike5 spike6 spike7 spike8 spike9
