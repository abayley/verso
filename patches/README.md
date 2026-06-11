# MicroHttp Patches

Local patches against external dependencies, kept here so they can be
reapplied after a reinstall. They are not applied automatically.

## MicroHs bspack Corruption Workaround

File: `microhs-bspack-nonpreempt.patch`

Patches the MicroHs runtime so the ByteString list-walk primitives
(`evalstring`, `evalbytestring`) run without being rescheduled mid-walk. This
works around a runtime bug where forcing a large lazily constructed
`ByteString` after any `forkIO` yields an empty, memoised result. The full
diagnosis is in
[../docs/microhs-bytestring-bug-report.md](../docs/microhs-bytestring-bug-report.md).

The patch trades latency for correctness: a large `pack` now completes
without yielding to other threads. Remove it once MicroHs ships a fix.

### MicroHs Patch Apply

The patch is in `git diff` format with `a/` and `b/` path prefixes, so apply
it with `-p1` from the root of the MicroHs source checkout:

```sh
cd /path/to/MicroHs
patch -p1 < /path/to/micro-http/patches/microhs-bspack-nonpreempt.patch
```

Then rebuild and reinstall MicroHs so the patched runtime is copied into the
mcabal package data directory that `mhs` compiles against. After any MicroHs
reinstall that overwrites the runtime, reapply this patch.

### MicroHs Patch Verify

`spike/MicroHttp/Spike11.hs` is the regression check. Without the patch it
prints `0` for the large pack; with the patch it prints the correct length:

```sh
make spike11 && build/spike11   # expect: 1000 then 5000
```

`spike/MicroHttp/Spike10.hs` is the socket-level check: it deadlocks without
the patch and completes all iterations with it.
