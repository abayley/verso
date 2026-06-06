MHS = ../MicroHs/bin/mhs
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.0.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
SPIKE = spike
SRC = src
TEST = test
DOCS = docs
DOC_FILES = INSTALL.md "$(DOCS)/**/*.md"

.PHONY: docs test-facade test-html test-http test-parser test-response test-router test-server test-socket test spike1 spike2 spike3 spike4 spike5 spike6 spike7 spike8 spike9 all-spikes check clean

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

test-facade:
	$(MHS) $(MHSFLAGS) -i$(SRC) $(TEST)/MicroHttpTest.hs -o facade-test
	./facade-test

test-html:
	$(MHS) $(MHSFLAGS) -i$(SRC) $(TEST)/MicroHttp/HtmlTest.hs -o html-test
	./html-test

test-http:
	$(MHS) $(MHSFLAGS) -i$(SRC) $(TEST)/MicroHttp/HttpTest.hs -o http-test
	./http-test

test-parser:
	$(MHS) $(MHSFLAGS) -i$(SRC) $(TEST)/MicroHttp/Http/ParserTest.hs -o parser-test
	./parser-test

test-response:
	$(MHS) $(MHSFLAGS) -i$(SRC) $(TEST)/MicroHttp/Http/ResponseTest.hs -o response-test
	./response-test

test-router:
	$(MHS) $(MHSFLAGS) -i$(SRC) $(TEST)/MicroHttp/RouterTest.hs -o router-test
	./router-test

test-server:
	$(MHS) $(MHSFLAGS) -i$(SRC) $(TEST)/MicroHttp/ServerTest.hs -o server-test
	./server-test

test-socket:
	$(MHS) $(MHSFLAGS) -i$(SRC) $(TEST)/MicroHttp/Network/SocketTest.hs -o socket-test
	./socket-test

test: test-facade test-html test-http test-parser test-response test-router test-server test-socket

check: docs test all-spikes

clean:
	rm -f facade-test html-test http-test parser-test response-test router-test server-test socket-test spike1 spike2 spike3 spike4 spike5 spike6 spike7 spike8 spike9
