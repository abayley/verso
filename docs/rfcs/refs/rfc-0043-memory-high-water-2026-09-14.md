# RFC-0043 Memory High-Water Mark (2026-09-14)

Supporting evidence for [RFC-0043](../implemented/rfc-0043-streaming-io-by-default.md), phase 1: the first
runs of `make bench-memory` (`test/bench/memory-bench.sh`), taken on the remediated tree after the
RFC-0043 conversions, on the same workstation as the RFC-0039 heap sizing runs. Search was off in every
run.

## Memory Bench Method

The script starts `build/verso` on a private port at the given `VERSO_HEAP_CELLS`, samples the server's
resident set with `ps` every 100ms, and drives one scenario at a time. "peak" is the largest sample inside
the scenario's window and "base" the last sample before it. At the end the server is stopped and
`/usr/bin/time -l` reports the kernel's own maximum resident set for the whole run, which is the figure to
trust; the sampled peaks agreed with it to within 2MB in every run. The demo corpus is a scratch copy of
the search-demo tree (22 pages, largest 73KB); the real corpus is `cello-docs` (3,980 pages, largest
263KB), run read-only.

## Memory Bench Results

Demo corpus, all six scenarios:

| Scenario                                  | 8M cells peak MB | 8M base MB | 4M cells peak MB | 4M base MB |
| ----------------------------------------- | ---------------- | ---------- | ---------------- | ---------- |
| 1 cold start (link-index build)           | 153              |            | 88               |            |
| 2 twelve sequential edit-view reads       | 150              | 119        | 82               | 89         |
| 3 four concurrent edit-view reads         | 146              | 142        | 81               | 81         |
| 4 one raw asset upload of 8 MiB           | 146              | 146        | 88               | 80         |
| 5 one no-JS form save of the largest page | 147              | 33         | 88               | 81         |
| 6 move the largest page away and back     | 155              | 127        | 90               | 84         |
| kernel maximum resident set               | 155              |            | 91               |            |

Real corpus, read-only scenarios:

| Scenario                            | 8M cells peak MB | 8M base MB | 4M cells peak MB | 4M base MB |
| ----------------------------------- | ---------------- | ---------- | ---------------- | ---------- |
| 1 cold start (link-index build)     | 160              |            | 90               |            |
| 2 twelve sequential edit-view reads | 148              | 138        | 81               | 78         |
| 3 four concurrent edit-view reads   | 148              | 135        | 86               | 80         |
| kernel maximum resident set         | 160              |            | 90               |            |

## Memory Bench Reading

- The high-water mark is the arena plus about 30MB. At 8M cells (122MB arena) the kernel maximum was
  155MB on the demo corpus and 160MB on the real one; at 4M cells (61MB arena) it was 91MB and 90MB. No
  scenario took the process more than a few MB above where the cold start had already put it. The
  streamed paths (the 8MiB upload, the form save, the move, the 263KB edit view four times at once) add
  nothing visible at this resolution, which is what the constant-space series set out to achieve.
- The cold start is the peak in every run. The link-index build on the real corpus (160MB at 8M) is the
  largest transient the server has when search is off.
- The base column is noisy and should not be subtracted from the peak. `ps`'s RSS on macOS excludes
  pages the memory compressor has taken, and the samples show the process dropping to 17 to 40MB for a
  second or two mid-run (during the 8MiB upload in the 8M demo run, for example) before climbing back to
  the arena size. The kernel's maximum resident set is unaffected by this and is the number to compare
  between runs. The dip was not investigated further; it does not change the high-water mark.
- These runs say nothing about search. With search on, the ONNX runtime and lancedb dominate resident
  memory (RFC-0040 phase 7 measured a ~200MB transient per indexed page), and the RFC-0039 sizing run
  recorded 269MB at ready with the model loaded. A search-on scenario set is the open question in the RFC.
