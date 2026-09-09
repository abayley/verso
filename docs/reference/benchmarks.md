# MicroHttp Benchmarks

Benchmarks are measurement tools. None of them is part of the `make check`
quality gate; treat the numbers as regression signals, not production figures.
Benchmark sources live under `test/bench/`, and compiled binaries are written under
`build/`.

## Socket Throughput Baseline

```sh
make bench-socket
```

This measures `MicroHttp.Network.Socket` loopback throughput in isolation from
the iteratee layer, in single-threaded transfer rounds, and reports MB/s per
recv buffer size. The bench source is `test/bench/SocketBench.hs`.

## Saturated Socket Throughput

```sh
make bench-socket-saturated
```

This drives a two-process transfer: a GHC blocking sender (`test/bench/sender/`,
built with Cabal and the `network` package) keeps the pipe full while the
MicroHs receiver (`test/bench/SocketReceiver.hs`) drains it through the production
`recv` loop. It reports the receiver's true recv ceiling, which the
single-threaded ping-pong bench cannot show because that one is bounded by the
non-blocking poll delay. Requires GHC, Cabal, and the `network` package.

## Iteratee Receive-Path Overhead

```sh
make bench-iteratee
```

This reuses the same saturated two-process harness, but the MicroHs receiver
(`test/bench/IterateeReceiver.hs`) drains the stream both with the raw `recv` loop
and through `socketEnumerator` into a counting consumer, reporting MB/s for
each so the iteratee overhead is the delta. It answers whether the iteratee
layer keeps up with the socket; both paths are constant-memory.

## Egress Send-Path Overhead

```sh
make bench-egress
```

The same harness with roles swapped: the MicroHs sender
(`test/bench/EgressSender.hs`) is the subject and sends each method's stream (plain
`sendAll` versus a chunked body enumerator driven into `socketSinkI`), while
the GHC drainer keeps the pipe empty. It reports the iteratee egress overhead
against the plain-`sendAll` baseline.

## HTML Builder Comparison

```sh
make bench-html-builder
```

The RFC-0013 measurement spike (`test/bench/HtmlBuilderBench.hs`): it renders a
representative page many times through each candidate builder representation
(String writer, naive `ByteString` append, difference lists, chunk ropes) and
reports CPU time per strategy.

## End-to-End HTTP Request Rate

```sh
make bench-http
```

This runs `test/bench/http-bench.sh`, which builds and starts the Verso server on
a private port, then drives it with ApacheBench over new connections,
comparing the in-memory builder path (`StrictBody`) against the zero-copy
sendfile path (`FileBody`) at a few payload sizes. Recorded results and
interpretation are in [HTTP Benchmark](../guides/http-benchmark.md).
