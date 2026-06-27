# Link index: how it works and where the performance costs lie

Status: analysis (2026-06-26). Companion to RFC-0029 and ADR-066/067.

This documents the in-memory link index (RFC-0029) as built, what each part costs
**measured on the reference corpus**, why move/delete are not yet sub-second despite
the FFI `stat`, and the options for making them snappy. It exists because the index
caused repeated production breakage (a minute-long "hang" on delete) and the cost model
was not written down.

## Reference corpus

A copy of the real documentation tree, used for all numbers below:

- 3,916 `.md` files, ~15.5 MB of Markdown.
- ~32,000 total filesystem entries (the rest are assets/images), directory depth 11.
- Some pages are link-dense; a few are large (up to ~260 KB).

Runtime: the server is compiled by **MicroHs** (mhs), a Haskell-to-combinator
compiler whose interpreter is markedly slower than GHC, especially for `String`
(linked-list-of-`Char`) processing. This matters a lot below.

## How the index works

Three pieces (see RFC-0029):

1. **The graph** (`MicroHttp.LinkIndex`): the resolved `.md`->`.md` link graph.
   `outbound :: Map PagePath [TreePath]` is each page's link targets; `inbound` is the
   inverse (`target -> referring pages`). Built by parsing every page's links
   (`DocumentLinks.pageLinks` + `resolveTarget`). A move/delete consults `inbound` to
   find referrers / the rewrite set in O(1), instead of scanning the tree.

2. **The freshness fingerprint** (`MicroHttp.LinkFingerprint`): a
   `Map TreePath (mtime, size)` over every `.md`, captured from `stat(2)` (the FFI
   binding). Held alongside the graph as the record of the tree the graph was built
   from.

3. **The per-operation freshness check** (`MicroHttp.LinkIndexStore`): before a
   move/delete the server re-walks the tree, re-stats every `.md`, and compares to the
   stored fingerprint. Match -> the graph is provably current, serve the lookup.
   Mismatch (an out-of-band edit) -> rebuild graph + fingerprint first. In-server
   mutations re-sync the held index so they are not mistaken for drift (ADR-067). This
   is what makes the index *always correct* -- no staleness window.

The graph is held in an `MVar`, built lazily on first use (or, since the eager-build
fix, at startup), and shared across the server's connection threads.

## Measured costs

### Build (constructing the whole graph): ~80-130 s

Forcing the full graph on the reference corpus takes **~80-130 s of CPU**. This is the
dominant cost and the source of the original "hang".

What it is **not**:

- Not the O(line^2) link scanner. `pageLinks`/`lineLinks` were quadratic per line
  (recomputing `length`/`drop i` per character); that is fixed (now O(line)). This is
  worth keeping regardless -- it also speeds the scan.
- Not the sorted-inbound insert. Suspecting `insertSorted` was O(degree) per edge
  (O(sum degree^2) on hub pages), it was measured both ways: **sorted 127.9 s vs
  unsorted 129.6 s -- no difference.**

What it **is**: the constant-factor cost of processing ~15.5 MB of Markdown as
`String` (via `BS.unpack`) in the mhs interpreter -- parsing every file's links,
`nub`-ing, and building the maps, with the attendant allocation/GC. The build
*inherently* parses every file (that is what a whole-tree graph is); the scan parses
only the few files whose bytes contain the target's name, which is why the scan never
paid this.

The graph is built **lazily** unless forced: constructing `IndexState (buildIndex ...)`
stores a thunk. The original bug was that the "eager build" forced only the fingerprint
(the ~2 s stat-walk), leaving the parse as a thunk that the **first move/delete** then
forced inside its handler -- a 129 s request. Forcing the graph at build time
(`forceIndex` + `seq`) fixes the misattribution but moves the ~80-130 s to startup.

### Per operation, warm (freshness check + lookup): ~2.6 s

With a warm, forced index, a delete is **~2.6 s**, and it is almost entirely the
**freshness walk**, not the lookup:

- The graph lookup (`inbound`/`rewriteCandidates`) is O(1)-ish and negligible.
- Each freshness pass walks the tree -- `listDirectory` per directory, plus
  `doesDirectoryExist` per entry, plus `fileStat` per `.md` -- over a 32k-entry,
  depth-11 tree: **~1.3 s**.
- A move/delete does this **twice**: once for the pre-op freshness check
  (`freshIndex`) and once for the post-op re-sync (`resync`). 2 x ~1.3 s ~= 2.6 s.

### The scan baseline (no index): ~3.5 s/op, 0 startup

The pre-index path (`enumerateRelevant`, RFC-0027) reads every `.md`'s bytes (to
byte-filter on the target name) and parses only the matches. On this corpus it is
**~3.5 s/op** with no startup cost -- dominated by the walk plus opening/reading 3,916
files.

## Why it is not sub-second (the FFI `stat` promise)

The lookup the index exists for **is** sub-millisecond. What is not sub-second is the
**freshness check**, and that is the key thing to understand: it is a *policy choice*,
not an inherent cost of having an index.

The index avoids the scan's per-op **read-and-parse** of every file. But ADR-067 added
a different per-op cost: before trusting the cached graph, the server **re-walks the
tree and re-`stat`s every `.md`** to prove nothing changed out-of-band since the graph
was built. That is the ~1.3 s. It buys "never serve a stale answer, no staleness
window" -- and it is paid on *every* operation, **twice** (the pre-op check and the
post-op re-sync). The FFI `stat` made this check metadata-only (cheaper than reading
every file; ~0.3 s on a *shallow* synthetic tree, which is where "sub-second" came
from), but a full traversal of a deep 32k-entry tree is ~1.3 s regardless of how cheap
each `stat` is.

So the per-op cost is **freshness verification**, not the lookup. The lever for snappy
operations is therefore *how out-of-band drift is detected*, not how fast the walk is:

- **A full per-op stat-walk** (current): always correct, no staleness window; ~1.3 s
  (x2). A/B below make this ~0.6 s but cannot remove it.
- **Freshness off the per-op path**: rebuild at startup, maintain incrementally for
  in-server edits, and rebuild on an explicit refresh after the periodic re-export
  (RFC-0028) -- the only routine out-of-band event, and a *known* moment. Then a
  move/delete is just the O(1) lookup: **sub-millisecond, no walk.** The cost is no
  longer auto-detecting *ad-hoc* direct edits to files on disk between refreshes.

Which is right depends on whether files are ever edited out-of-band *other than* by the
re-export while the server runs. If not, the per-op walk is pure overhead.

The **build** is a separate, larger cost the per-op model did not face: ~80-130 s to
parse the whole tree into the graph, in the mhs interpreter, over `String`. This is what
C (ByteString engine) and E (persistence) address; they do **not** touch the per-op
freshness walk.

## Options

Each option lists impact, tradeoff, and rough effort. They compose.

### Per-operation latency

- **A. One walk per op.** Maintain the index from the operation's known write-set
  (re-stat only the files it changed) instead of `resync` re-walking the whole tree.
  Impact: ~2.6 s -> ~1.3 s. Tradeoff: none (still always-correct). Effort: moderate
  (thread the write-set; the pre-op `freshIndex` walk stays).
- **B. One `stat` per entry.** The walk currently does `doesDirectoryExist` (a stat)
  *and* `fileStat` (another stat) per entry. A single `stat` returning `st_mode` tells
  both dir-vs-file and mtime/size. Impact: roughly halves walk syscalls -> ~0.6-0.7 s
  per walk. Tradeoff: none. Effort: small (extend the FFI binding + the walk).

A + B together put a warm move/delete around **~0.6 s -- snappy**, keeping the
always-correct guarantee.

### Build latency (the ~80-130 s)

- **C. ByteString-native link engine.** Read files as `ByteString` and scan them
  directly (O(1) `BS.index`/`BS.length`), never `BS.unpack`ing to `String`. The link
  engine already treats content as bytes (offsets are byte offsets), so this is a
  representation change, not a semantic one. Impact: build ~80-130 s -> ~seconds, *and*
  the scan gets faster too. Tradeoff: it is the engine that drives byte-exact rewrites,
  so the spans must stay correct -- correctness-sensitive, but `DocumentLinksSpec` pins
  them. Effort: large. **Highest leverage single change.**
- **D. Background build + scan fallback.** Build the index on a background thread at
  startup; until it is ready, move/delete use the scan (~3.5 s). Impact: instant
  startup, snappy once warm, no minute-long stall. Tradeoff: a window of scan-speed ops
  after start; concurrency to get right. Effort: moderate.
- **E. Persist the index.** Serialise graph + fingerprint to disk; reload on restart
  (the fingerprint check still validates it). Impact: saves the *parse* on restart, but
  **not** the `Map`/inbound construction (which dominates in mhs and cannot be skipped
  when deserialising `Data.Map`), so it helped less than expected -- ~40 s build vs ~25 s
  reload (see Implemented outcome). Tradeoff: a serialise/validate path. Effort: moderate.
- **Accept eager startup.** Force the graph at startup and live with ~80-130 s before
  serving. Simplest, but a poor operational experience that grows with the corpus.

### Freshness model (the real per-op lever)

- **F. Freshness off the per-op path.** Build at startup, maintain incrementally for
  in-server edits, and rebuild on an **explicit refresh** after the periodic re-export
  (the re-export script hits an endpoint / sends a signal). No per-op walk. Impact: a
  move/delete becomes the O(1) lookup -- **sub-millisecond**, regardless of A/B.
  Tradeoff: ad-hoc direct edits to files on disk between refreshes are not auto-detected
  (a bounded staleness window; ADR-067 traded this away). Appropriate when the re-export
  is the only routine out-of-band writer. Effort: small-moderate (a refresh trigger;
  drop the per-op check).
- **F'. Cheaper per-op check.** If automatic detection must stay, a coarser signal than
  a full per-`.md` walk -- e.g. a sentinel file the re-export touches (one `stat`), or a
  directory-mtime sweep (detects added/removed/renamed entries, but **not** in-place
  content edits, since editing a file does not change its parent directory's mtime).
  Impact varies; weaker guarantee than the full walk for the sentinel/dir-mtime
  variants.

### No index

- **G. Revert to the scan.** Move/delete use `enumerateRelevant` (~3.5 s/op, 0 startup,
  always correct). Simplest and reliable; loses snappiness. The index code stays in the
  tree, dormant, re-enabled by one wiring change.

## Implemented outcome (2026-06-26)

C + E + F were implemented (the index is back in move/delete). Measured on the
reference corpus:

- **Operations are snappy: ~39 ms** for move/delete -- the warm index is read with no
  filesystem walk (F), and maintenance is incremental (a move is a pure prefix
  relocation; delete/save/create/restore re-read only their few touched paths).
- **Startup build + persist: ~40 s** (a one-off; C's ByteString parse is fast, so this
  is dominated by mhs `Map`/inbound construction).
- **Reload from the persisted file: ~25 s.** Persistence (E) saves the *parse* but
  **not** the `Map` construction -- `Data.Map` cannot be deserialised without re-inserting
  every element, which is the dominant cost in the mhs interpreter. So persistence helps
  less than hoped (~40 s -> ~25 s); it is kept because it still saves the parse and
  validates correctness, but the startup cost is not sub-second.
- **Refresh** (`POST /index/refresh`, for the re-export to call) rebuilds in ~the build
  time.

So the user-facing goal (snappy move/delete) is met; the residual cost is a ~25-40 s
one-off at startup. If that startup cost matters, the lever is the `Map`/inbound build
(e.g. a flatter in-memory representation, or building inbound unsorted) -- not the parse
or persistence.

## Profiling outcome (2026-06-27) -- the startup bottleneck, measured per phase

The 2026-06-26 outcome above **mis-attributed the startup cost to the `Map`/inbound
build.** Per-phase timing (forced at each phase boundary so laziness cannot shift cost
between phases; emitted at startup via `openLinkIndexWith`) shows the `Map` build is
~1.6 s and was never the bottleneck. There are two slow paths, with two *different*
dominant costs, neither of them the `Map`:

### Reload path (persisted index valid): `BS.lines` was O(n^2) -- fixed

| phase | before | after |
| --- | --- | --- |
| read index file | 1 ms | 1 ms |
| split + parse rows | **23,307 ms** | **729 ms** |
| build graph from edges (`Map`/inbound) | 1,645 ms | 1,610 ms |
| build stored fingerprint | 86 ms | 179 ms |
| fingerprint tree (stat walk) | 869 ms | 957 ms |

Decomposing the 23.3 s parse: `BS.lines` alone was **22,089 ms**; `BS.split '\t'` 100 ms;
`BS.unpack` of every field (the `String` conversion) **7 ms**; `parseRow` 396 ms. mhs's
`Data.ByteString.Char8.lines` is O(n^2). The fix is one line -- `BS.lines` ->
`BS.split '\n'` (the `null` filter drops the trailing empty element, so the rows are
identical). **Reload startup ~26 s -> ~3.7 s.** (A reported 65 s startup was this same
O(n^2) under heavier machine load.) Note the `String` conversion the persistence layer
still does is *not* a cost (7 ms); a ByteString-keyed graph/persistence would not help.

### Cold build / refresh path: the body parse dominates (~36 s) -- open

| phase | time |
| --- | --- |
| walk tree (list .md) | 238 ms |
| read + stat files | 683 ms |
| parse bodies + build graph | **36,607 ms** |
| build fingerprint map | 376 ms |
| persist (write index) | 258 ms |

`buildFromBodies` = parse + `Map` build; the reload path's "build graph from edges" does
the *same* `Map` build from pre-resolved edges in ~1.6 s. So the ~35 s delta is the
**body link-parsing** (`DocumentLinks.pageLinks` + `resolveTarget` in `updatePage`),
~9 ms/file over 3,917 files. This contradicts the earlier "the lever is the `Map` build,
NOT the parse" -- it is the parse. `unlines` on write (persist) is fine at 258 ms. This
path runs on first start and on every `POST /index/refresh` after a re-export; making it
fast means profiling `pageLinks` for a remaining per-file hotspot (a prior O(line^2) fix
in `lineLinks` landed in `8a376f6`; there may be another).

## Recommendation

The two cost centres are independent and need different fixes:

- **Build (~80-130 s):** **C** (ByteString engine) brings it to ~seconds and speeds the
  scan too; **E** (persist) then makes it a one-off, reloaded fast on restart and
  validated by the fingerprint.
- **Per-op (~2.6 s):** this is the freshness walk, not the lookup. **A + B** shave it to
  ~0.6 s while keeping always-correct; **F** (freshness off the per-op path) removes it
  entirely for **sub-millisecond** ops, trading away auto-detection of ad-hoc on-disk
  edits between re-exports.

**Chosen direction: E + C.** That makes the build cheap and persistent. To also make
operations snappy, pair it with a per-op decision: **F** if the re-export is the only
routine out-of-band writer (sub-ms ops, the model that matches "the index avoids
walks"), or **A + B** if automatic per-op correctness must stay (~0.6 s ops).

Sequencing (each independently shippable, scan stays the fallback throughout):

1. Split the `lineLinks` O(n) fix into its own commit (a clean win for the scan today).
2. **C** -- ByteString link engine; re-measure the build.
3. **E** -- persist graph + fingerprint; reload-and-validate on startup.
4. Per-op: **F** (refresh-triggered) or **A + B** (cheaper walk), per the freshness
   decision above.

Until C+E land, **revert move/delete to the scan (G)** so deletes are reliable
(~3.5 s/op, no startup penalty) rather than shipping the lazy-build hang or an
80-130 s eager startup.

## Error handling (Either, not exceptions)

The project models failure with `Either`/`ExceptT`, not exceptions. The index/IO code
can still *throw* (file reads, the FFI `stat`, partial functions), so that code should
run in `ExceptT` and surface failures as `Either`, rather than being guarded by a
catch-all `try`/`SomeException` at the server boundary. The temporary `try` added to
`handleClient` during diagnosis should be removed and replaced by `ExceptT` at the
points that can fail. (The `SIGPIPE` ignore is unrelated -- that is OS-signal handling
for client disconnects, not exception-as-control-flow.)
