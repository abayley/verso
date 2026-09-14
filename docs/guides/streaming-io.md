# Streaming I/O Recipes

How to read a file or a subprocess's output without holding it whole. Streaming is the default for
production code (ADR-0091, RFC-0043): a `readFile` in `packages/*/src` must carry a same-line
`-- whole-file: <bound>` comment stating why the input is small, or `make lint` fails. Everything below is
in `MicroHttp.Stream` and `MicroHttp.Process`; every function returns `Either StreamError a` where a read
can fail, and a file that will not open is a `StreamSourceError`, not an exception.

## Why Streaming Matters on MicroHs

The MicroHs heap is a fixed arena of cells, but a `ByteString`'s bytes are not in it: each `ByteString` is
one cell pointing at a `malloc`'d buffer, freed by a finalizer when the collector next runs. The collector
runs when cells run out, not when bytes do. So a whole-file `BS.readFile` never exhausts the heap; it
inflates the process's resident memory until an unrelated collection happens, and a `BS.take` or `BS.drop`
view keeps the whole buffer alive. Streaming keeps the live bytes at one block, whatever the file size.
`make bench-memory` measures the resident high-water mark for a fixed scenario set.

## Streaming Recipe Table

| Shape of the read                  | Recipe                                                                                                        |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Parse a line-oriented file         | `Stream.foldFileLines step initial path`                                                                      |
| Scan a file in fixed blocks        | `Stream.foldFileBlocks blockBytes step initial path`                                                          |
| Does a file contain these bytes    | `Stream.fileContains needle path`                                                                             |
| Are two files byte-identical       | `Stream.filesEqual a b`                                                                                       |
| Copy a file                        | `Stream.copyFile from to`                                                                                     |
| Write a file as lines              | `Stream.writeFileLines path lines`                                                                            |
| Parse a subprocess's output        | `Process.withCapture exe args cwd stdin (\cap -> Stream.foldFileLines step initial (Process.captureOut cap))` |
| Serve a file as a response body    | `Http.FileBody path`, or `Stream.transformedFileBody` for a per-block rewrite                                 |
| Receive a request body into a file | `Stream.fileSinkI limit tooLarge path` driven by the request enumerator                                       |

`step :: a -> BS.ByteString -> IO a` receives each line (no trailing newline) or block and returns the new
accumulator. Prepend to a list and `reverse` at the end when order matters; a `Map` or a count needs no
reversal.

## Worked Conversion: the Link Index Load

Before (RFC-0029), the persisted index was read whole and split into rows:

```haskell
bytes <- tryIO (BS.readFile indexPath)
case parseRows bytes of
    Nothing -> pure Nothing
    Just rows -> reuseOrRebuild rows
```

After (RFC-0043), the same `parseRow` runs once per line as the file is read, and a malformed line marks
the file corrupt:

```haskell
folded <- tryIO (Stream.foldFileLines collectRow (Just []) indexPath)
case folded of
    Right (Just rows) -> reuseOrRebuild rows
    _ -> pure Nothing

collectRow :: Maybe [Row] -> BS.ByteString -> IO (Maybe [Row])
collectRow acc line
    | BS.null line = pure acc
    | otherwise = pure (acc >>= \rows -> fmap (: rows) (parseRow (map BS.unpack (Bytes.split '\t' line))))
```

The conversion pattern is always the same three moves: the whole-value parser becomes a per-line (or
per-block) step, the accumulator carries whatever the parser used to return, and the `Left` from the fold
takes over the "file unreadable" branch.

## Subprocess Output

`Process.runProcess` reads both outputs whole and is for commands that print a status line or a hash.
A command whose output grows with the data runs under `Process.withCapture`, which removes the capture
files however the consumer exits:

```haskell
logForPath root path =
    Process.withCapture "git" ["-C", root, "log", "--format=" ++ logFormat, "--", path] Nothing Nothing $ \cap ->
        case Process.captureExit cap of
            Exit.ExitSuccess -> either (const []) reverse <$> Stream.foldFileLines collect [] (Process.captureOut cap)
            _ -> pure []
```

A capture that is served rather than parsed is renamed or streamed into place instead of folded
(`Git.showFileAtRevisionCaptured` and the rollback handler are the example).

## Splitting Inside a Line or Block

Inside a step, split with `MicroHttp.Bytes` (`Bytes.split`, `Bytes.isInfixOf`), not `Data.ByteString`'s
`split`, `lines` or `elemIndex`: on MicroHs those unpack the whole value to a list, which is quadratic in a
loop and can overflow the collector's fixed stack on a large value.
