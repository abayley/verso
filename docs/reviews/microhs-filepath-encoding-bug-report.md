# MicroHs File Path Encoding Bug Report

This document is a bug report prepared for the MicroHs project. It is not a MicroHttp design document;
it records a fault found while removing the bytes-as-`Char` convention from Verso (RFC-0043). It is the
reason a non-ASCII document file name is unsupported when Verso is built with MicroHs, and the reason the
`LinkIndexStoreSpec` case for such a name exists only in the GHC run.

> **Status (2026-09-15): open on the installed toolchain (MicroHs 0.16.5.0).** Workarounds considered
> and deferred: routing every path operation through MicroHttp's own FFI (which marshals UTF-8), or
> decoding directory listings under MicroHs only. Re-test when the toolchain updates.

## Title

`System.IO` and `System.Directory` marshal `FilePath` one byte per `Char`, so a path holding characters
above U+00FF cannot be created, opened or listed.

## Environment

- MicroHs 0.16.5.0 (`~/.mcabal/mhs-0.16.5.0`), macOS 27.0 on arm64, APFS (file names must be valid UTF-8).
- GHC 9.6.7 for the comparison run.

## Observed

`lib/System/Directory.hs` (`getDirectoryContents`) passes the directory with `withCAString` and reads each
entry with `peekCAString`; `lib/System/IO/Base.hs` opens files through `newCAStringLen`. `withCAString`
and `peekCAString` truncate each `Char` to its low byte and widen each byte to a `Char`, so:

- `BS.writeFile "dir/caf\233 \8212 \1046.md"` fails with `openBinaryFile: does not exist`: the name reaching
  `fopen` is the bytes `E9 20 14 20 16`, which is not valid UTF-8 and which APFS refuses.
- A name that does exist on disk (created by another program as UTF-8) is listed by `listDirectory` as one
  `Char` per byte (`caf\195\169 ...`), and passing that listing back to `openBinaryFile` re-truncates it,
  so the listed file cannot be reopened through the library either.
- A program that marshals paths itself with `withCString` (UTF-8), as MicroHttp's `FileSystem` module
  does, sees the real name, so the two halves of one program disagree about which files exist.

## Reproduction

```haskell
import qualified Data.ByteString.Char8 as BS
import qualified System.Directory as Directory

main :: IO ()
main = do
    BS.writeFile "probe/caf\233 \8212 \1046.md" (BS.pack "x") -- throws under mhs, succeeds under GHC
    names <- Directory.listDirectory "probe"
    print (map (map fromEnum) names)                          -- under mhs: bytes, not characters
```

Under GHC both lines behave as expected and the file round-trips. The Verso unit case "given a page
whose name holds characters above Latin-1, when the index is persisted and reloaded, then it is reused
with the name intact" passes under GHC (550 examples) and fails under MicroHs with
`openBinaryFile: does not exist` at the first write.

## Expected

`FilePath` marshalled as UTF-8 in both directions, as GHC's file system encoding does on a UTF-8 locale:
`withCString`/`peekCString` (or the locale encoding) in `System.Directory` and `System.IO`.

## Impact on MicroHttp and Verso

Document, section and asset names are user-chosen and reach the file system as `FilePath`s built from
decoded route captures. Any name with a character above U+00FF cannot be created under MicroHs, and any
such name already in a corpus is listed wrongly and cannot be opened by the library calls (the FFI calls
in `MicroHttp.FileSystem` do open it). ASCII and Latin-1 names in the range U+0080 to U+00FF are also
affected, because their single-byte truncation is not valid UTF-8 on APFS.
