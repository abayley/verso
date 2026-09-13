# Configuration Reference

Every configuration key the server reads, with its type and default. The source of truth is the code:
framework (server) keys live in `packages/micro-http/src/MicroHttp/Config.hs` and
`packages/micro-http/src/MicroHttp/Settings.hs`; application keys live in
`packages/verso/src/Verso/Config.hs`. This page is a generated-by-hand catalogue of those; when a key
changes there, change it here.

## Loading

The server reads a single config file, `micro-http.conf` by default, overridden by the `MICROHTTP_CONFIG`
environment variable. The file is `key = value`, one per line; blank lines and `#` comments are ignored.
`micro-http.conf.example` is a worked example.

Two environment overlays sit over the file, each scoped to a disjoint set of keys so neither can reach the
other's:

- `MICROHTTP_<KEY>` overrides a framework (server) key. Example: `MICROHTTP_PORT=9000`.
- `VERSO_<KEY>` overrides an application key. Example: `VERSO_LOG_KEEP=9`.

The variable name is the key uppercased with the prefix, so `port` is `MICROHTTP_PORT` and `log_keep` is
`VERSO_LOG_KEEP`. An environment value beats the file value; the file value beats the built-in default.

## Framework Keys

Server-level keys, mapped onto the socket server's `Settings`. Overlaid by `MICROHTTP_<KEY>`.

| Key                         | Type | Default     | Meaning                                                                       |
| --------------------------- | ---- | ----------- | ----------------------------------------------------------------------------- |
| `host`                      | host | `127.0.0.1` | Bind address. Loopback by default; set `0.0.0.0` to listen on all interfaces. |
| `port`                      | int  | `8080`      | Listen port.                                                                  |
| `backlog`                   | int  | `16`        | Listen backlog passed to `listen(2)`.                                         |
| `max_active_handlers`       | int  | `32`        | Cap on concurrent request handlers (bounded concurrency).                     |
| `max_header_bytes`          | int  | `8192`      | Maximum request-head size before the request is rejected.                     |
| `max_body_bytes`            | int  | `10485760`  | Maximum request-body size (10 MiB). Handler-level limits still apply.         |
| `read_buffer_bytes`         | int  | `8192`      | Socket read buffer size.                                                      |
| `idle_read_timeout_micros`  | int  | `30000000`  | Idle read timeout in microseconds (30 s), RFC-0006.                           |
| `idle_write_timeout_micros` | int  | `30000000`  | Idle write timeout in microseconds (30 s), RFC-0008.                          |

### Application Body Ceilings

`max_body_bytes` is the framework's outer bound. Inside it, each Verso handler applies its own fixed cap,
sized to the payload it accepts. These are constants in `Verso.App`, not configuration keys: they are
product policy (how large a page may be), not memory bounds: the raw `PUT` bodies stream to disk (RFC-0040)
and the no-JS form's remaining whole-body read is RFC-0042's. A `VERSO_` key for the page ceiling is the
recorded step should larger pages ever be needed.

| Payload                                                       | Cap    | Constant                                    |
| ------------------------------------------------------------- | ------ | ------------------------------------------- |
| A page: raw `PUT` publish, draft autosave, or the no-JS form  | 1 MiB  | `formBodyLimit`                             |
| An asset upload                                               | 10 MiB | `treeAssetMaxBytes`                         |
| An image-titles sync post                                     | 64 KiB | `imageTitlesBodyLimit`                      |
| Identifier posts (create, move, delete, rollback) and reports | 8 KiB  | `treeCreateMaxBytes`, `clientErrorMaxBytes` |

## Application Keys

Verso application keys. Overlaid by `VERSO_<KEY>`. `document_tree_root` is required; every other key takes
the default shown when absent.

| Key                     | Type   | Default                        | Meaning                                                                                 |
| ----------------------- | ------ | ------------------------------ | --------------------------------------------------------------------------------------- |
| `document_tree_root`    | string | (required)                     | The MkDocs-style tree served and edited in place (RFC-0026, RFC-0036).                  |
| `operation_log`         | string | `data/operation_log`           | Append-only log of move/delete/create operations (RFC-0028).                            |
| `trash_root`            | string | `data/trash`                   | Directory holding deleted documents with their provenance (RFC-0027, RFC-0028).         |
| `trash_retention_days`  | int    | `90`                           | Days before the trash sweep purges an entry; zero or negative disables the sweep.       |
| `link_index`            | string | `data/link_index`              | Path of the persisted intra-wiki link index (RFC-0029).                                 |
| `access_log`            | string | `build/access.log`             | Request access log (RFC-0009). Its parent directory is created at startup.              |
| `client_error_log`      | string | `build/client-errors.log`      | Sink for client error telemetry (RFC-0023). Its parent is created at startup.           |
| `log_max_bytes`         | int    | `10485760`                     | Log-rotation size threshold in bytes (10 MiB), RFC-0024.                                |
| `log_keep`              | int    | `5`                            | Number of rotated log files to retain (RFC-0024).                                       |
| `static_mounts`         | mounts | (none)                         | Extra static mounts, comma-separated `<url-prefix> <directory>` pairs.                  |
| `editor_static_dir`     | string | `packages/verso/static/editor` | Directory served at the fixed `/static/editor` URL: the editor bundles and assets.      |
| `versioning_enabled`    | bool   | `true`                         | Git-backed drafts, publish, history, diff, and rollback (RFC-0032).                     |
| `link_index_enabled`    | bool   | `true`                         | Whether the link index is built and maintained (RFC-0029).                              |
| `draft_root`            | string | `data/drafts`                  | Directory holding unpublished drafts (RFC-0032).                                        |
| `identity_header`       | string | `X-Remote-User`                | Request header naming the authenticated user.                                           |
| `identity_default`      | string | `anonymous`                    | User assumed when the identity header is absent.                                        |
| `identity_email_domain` | string | `verso.local`                  | Domain appended to a user name to form an email address.                                |
| `search_enabled`        | bool   | `false`                        | Enable hybrid search (RFC-0034). Needs the Concordance shim built (`make search-shim`). |
| `search_model`          | string | (none)                         | Path to the ONNX embedding model file.                                                  |
| `search_vocab`          | string | (none)                         | Path to the tokeniser vocabulary file.                                                  |
| `search_index`          | string | `data/search_index`            | Directory of the LanceDB search index.                                                  |
| `search_model_id`       | string | `bge-small-en-v1.5-q8`         | Model id recorded in the index; a mismatch on open forces a full rebuild.               |
| `search_pooling`        | string | `cls`                          | Embedding pooling strategy.                                                             |
| `search_max_tokens`     | int    | `384`                          | Token cap per embedded chunk.                                                           |
| `search_dims`           | int    | `384`                          | Embedding vector dimension.                                                             |
| `search_threads`        | int    | `4`                            | ONNX Runtime intra-op thread count.                                                     |
| `search_query_prefix`   | string | (none)                         | Text prepended to a query before embedding, when the model expects it.                  |

## Types

- **int** parses as a decimal integer; a malformed value fails startup.
- **bool** is `true` or `false`; anything else fails startup.
- **host** is an IPv4 address or a host the socket layer accepts.
- **string** is taken verbatim, trimmed of surrounding whitespace.
- **mounts** is a comma-separated list of `<url-prefix> <directory>` pairs, for example
  `/assets public/assets, /files data/files`.
