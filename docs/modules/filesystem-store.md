# Filesystem Store Module Design

## Filesystem Store Module Purpose

`MicroHttp.Store.FileSystem` provides a small filesystem-backed state adapter for
applications that do not need a traditional database.

## Filesystem Store Module Responsibilities

- Load state from a directory at startup.
- Maintain an in-memory index.
- Serialise write jobs through one writer thread.
- Write temporary files before replacing final files.
- Delete documents.
- Expose writer completion for tests and clean shutdown.

## Filesystem Store Module Non-Responsibilities

- HTTP routing.
- HTML rendering.
- Domain-specific document schemas.
- Multi-process locking.
- Cross-host replication.

## Filesystem Store Module Public Interface Sketch

```haskell
data Store key value
data WriteJob key value

loadStore :: StoreConfig -> IO (Store key value)
readStore :: Store key value -> STM [(key, value)]
enqueuePut :: Store key value -> key -> value -> IO ()
enqueueDelete :: Store key value -> key -> IO ()
stopStore :: Store key value -> IO ()
```

## Filesystem Store Module MicroHs Findings

Spike 6 proved `TQueue`, a single writer thread, overwrite, delete, memory
state, and reload from disk.

MicroHs currently exposes `removeFile` but not `renameFile`, so the store needs
a small `rename` FFI binding or a future MicroHs library addition.

## Filesystem Store Module Open Decisions

- Whether the library should provide this as a generic adapter or leave it to
  applications.
- Whether the first implementation should require a serialisation type class or
  accept explicit encode/decode functions.
- Whether writes update memory before or after disk success. The safer first
  contract is disk success first, memory update second.
