<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Nim Client</h1>

<p align="center">
  <b>Pure Nim client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No C ABI bindings and no external dependencies - built on the standard library <code>std/httpclient</code> and <code>std/json</code>. The API mirrors the MongrelDB PHP, Go, Java, and D clients.
</p>

<p align="center">
  <a href="https://nim-lang.org/"><img src="https://img.shields.io/badge/Nim-%3E%3D2.0-ffe953.svg" alt="Nim" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-Nim/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Nim/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Nim client | `mongreldb` | `nimble install mongreldb` |

## Requirements

- **Nim 2.0 or newer** (built and tested with Nim 2.2.10)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put` (insert), and `deleteByPk` (delete by primary key), with optional idempotency keys for safe retries.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` → `column_id`, `min`/`max` → `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation with `enumVariants` (constrained value sets) and `defaultValue` (server-side defaults), full schema catalog, and per-table descriptors.
- **Typed exceptions**: `AuthError` (401/403), `NotFoundError` (404), `ConflictError` (409, with error code + op index), and `QueryError` (everything else), all subclasses of `MongrelDBError` carrying the HTTP status and decoded server envelope.
- **Pluggable auth**: Bearer token (`--auth-token` mode) and HTTP Basic (`--auth-users` mode); the token takes precedence.
- **User/role/credentials management** via SQL: Argon2id-hashed catalog users, roles, and `GRANT`/`REVOKE` table-level permissions, all executed through `sql`.

## Examples

Runnable, end-to-end programs and deep dives for every feature live in
[`docs/`](docs/):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Batch transactions](docs/transactions.md) - atomic multi-op commits, idempotency, and retry.
- [Native query builder](docs/queries.md) - every condition type and the alias translation rules.
- [SQL](docs/sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`.
- [Authentication](docs/auth.md) - bearer token, basic auth, and user/role management via SQL.
- [Error handling](docs/errors.md) - the exception hierarchy and recovery patterns.

## Quick Example

```nim
import std/[json, options]
import mongreldb

# Connect to a running mongreldb-server daemon.
let db = newMongrelDB("http://127.0.0.1:8453")

# Create a table. Column ids are stable on-wire identifiers. `enumVariants`
# constrains the allowed values for `status`; the engine rejects writes that
# don't match the list. `defaultValue` (Option[string]) sets a server-side
# default that fills in when a put omits the column. Both fields are emitted
# on the wire only when populated.
discard db.createTable("orders", [
  Column(id: 1'i64, name: "id",       ty: "int64",   primaryKey: true,  nullable: false),
  Column(id: 2'i64, name: "customer", ty: "varchar", primaryKey: false, nullable: false),
  Column(id: 3'i64, name: "amount",   ty: "float64", primaryKey: false, nullable: false),
  Column(id: 4'i64, name: "status",   ty: "enum", primaryKey: false, nullable: false,
         enumVariants: @["pending", "paid", "shipped"]),
  Column(id: 5'i64, name: "created_at", ty: "timestamp_nanos",
         defaultValue: some("now")),
], %*{
  "checks": [{"id": 1, "name": "id_present", "expr": {"IsNotNull": 1}}],
})

# Insert rows (cells pair column id -> value). `status` must be one of the
# enum variants; `created_at` is omitted and the engine fills the current time.
discard db.put("orders", {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %99.50, 4'i64: %"pending"})
discard db.put("orders", {1'i64: %2'i64, 2'i64: %"Bob",   3'i64: %150.00, 4'i64: %"paid"})

# Query with a native index condition (learned-range index on a float64 column).
let rows = db.query("orders")
    .where("range_f64", parseJson("""{"column": 3, "min": 100.0, "max": 200.0, "min_inclusive": true, "max_inclusive": true}"""))
    .projection([1'i64, 2'i64])
    .limit(100)
    .execute()
echo "rows: ", rows.len

echo "count: ", db.count("orders") # 2

# Run SQL.
discard db.sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## Authentication

```nim
# Bearer token (--auth-token mode)
let db = newMongrelDB("http://127.0.0.1:8453", token = "my-secret-token")

# HTTP Basic (--auth-users mode)
let db2 = newMongrelDB("http://127.0.0.1:8453", username = "admin", password = "s3cret")

# Custom per-request timeout (milliseconds, default 30000)
var db3 = newMongrelDB("http://127.0.0.1:8453")
discard db3.setTimeout(60_000)
```

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign-key, and check constraints at commit time.

```nim
let txn = db.begin()
discard txn.put("orders", {1'i64: %10'i64, 2'i64: %"Dave", 3'i64: %50.00})
discard txn.put("orders", {1'i64: %11'i64, 2'i64: %"Eve",  3'i64: %75.00})
discard txn.deleteByPk("orders", %2'i64)

try:
  let results = txn.commit() # atomic - all or nothing
except ConflictError as e:
  # A constraint violation rolls back every op.
  echo "duplicate: ", e.msg, " code=", e.code, " op=", e.opIndex

# Idempotent commit - safe to retry; the daemon returns the original response.
let txn2 = db.begin()
discard txn2.put("orders", {1'i64: %20'i64, 2'i64: %"Frank", 3'i64: %100.00})
discard txn2.commit("order-20-create")
```

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(→ `column_id`), `min`/`max` (→ `lo`/`hi`), `min_inclusive`/`max_inclusive`
(→ `lo_inclusive`/`hi_inclusive`). The canonical keys are also accepted directly.
Use `range` for integer columns and `range_f64` for float64 columns.

```nim
# Bitmap equality (low-cardinality columns).
discard db.query("orders")
    .where("bitmap_eq", parseJson("""{"column": 2, "value": "Alice"}"""))
    .execute()

# Range query on a float64 column (use `range` for integer columns).
discard db.query("orders")
    .where("range_f64", parseJson("""{"column": 3, "min": 50.0, "max": 150.0, "min_inclusive": true, "max_inclusive": true}"""))
    .limit(100)
    .execute()

# Range query on an integer column.
discard db.query("orders")
    .where("range", parseJson("""{"column": 1, "min": 1, "max": 100}"""))
    .limit(100)
    .execute()

# Full-text search (FM-index).
discard db.query("documents")
    .where("fm_contains", parseJson("""{"column": 2, "value": "database performance"}"""))
    .limit(10)
    .execute()

# Check whether a result was capped by the limit.
let q = db.query("orders")
    .where("range_f64", parseJson("""{"column": 3, "min": 0.0, "max": 9999.0, "min_inclusive": true, "max_inclusive": true}"""))
    .limit(100)
let rows = q.execute()
if q.truncated:
  # result set hit the limit; more matches exist on the server
  discard
```

## SQL

```nim
discard db.sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
discard db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

# Recursive CTEs and window functions
discard db.sql("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")
discard db.sql("SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders")
```

> Note: the `/sql` endpoint streams Arrow IPC bytes for `SELECT`s. The client
> decodes JSON bodies when present and returns an empty seq otherwise (e.g.
> for DDL/DML or binary result sets).

## History retention

Control how far back time-travel queries can read. The window is measured in
epochs (monotonically increasing commit numbers).

```nim
# Keep at least 1000 epochs of history readable.
let result = db.setHistoryRetentionEpochs(1000)
echo result.historyRetentionEpochs  # 1000
echo result.earliestRetainedEpoch   # oldest epoch still available

echo db.historyRetentionEpochs()    # 1000
echo db.earliestRetainedEpoch()     # oldest readable epoch

# Read a table as it existed at a specific epoch.
let historical = db.sql("SELECT label FROM orders AS OF EPOCH 42 WHERE id = 1")
```

Raising retention prevents history from being garbage collected, but it cannot
restore epochs that have already been pruned. These endpoints require admin
privileges when the daemon runs with auth enabled.

## User & role management

When the daemon runs in `--auth-users` mode, users and roles live in the
catalog and are managed with SQL through `sql`.

```nim
# Create an Argon2id-hashed user.
discard db.sql("CREATE USER alice WITH PASSWORD 'hunter2'")

# Promote to administrator.
discard db.sql("ALTER USER alice ADMIN")

# Roles and table-level grants.
discard db.sql("CREATE ROLE analyst")
discard db.sql("GRANT SELECT ON orders TO analyst")
discard db.sql("GRANT analyst TO alice")
discard db.sql("REVOKE SELECT ON orders FROM analyst")
discard db.sql("DROP ROLE analyst")
discard db.sql("DROP USER alice")
```

See [docs/auth.md](docs/auth.md) for the full auth mode reference and user/role
recipes.

## Error handling

Every non-2xx response is mapped to a typed exception. Catch
`MongrelDBError` for any failure, or one of the specific subclasses.

```nim
try:
  discard db.schemaFor("missing_table")
except NotFoundError as e:
  echo "not found: ", e.msg, " (status ", e.status, ")"
except ConflictError as e:
  echo "constraint ", e.code, " at op ", e.opIndex
except AuthError:
  echo "not authorized"
except QueryError as e:
  echo "query/server error: ", e.msg
```

## API reference

### `MongrelDB`

| Method | Description |
|--------|-------------|
| `newMongrelDB(url = defaultBaseURL; token = ""; username = ""; password = "")` | Construct a client |
| `setTimeout(ms)` | Set per-request timeout (ms); returns `var MongrelDB` |
| `health()` | Check daemon health |
| `tableNames()` | List table names |
| `createTable(name, columns)` | Create a table; returns the table id |
| `dropTable(name)` | Drop a table |
| `count(table)` | Row count |
| `put(table, cells, idempotencyKey = "")` | Insert a row |
| `deleteByPk(table, pk)` | Delete by primary key |
| `query(table)` | Start a native query |
| `sql(sql)` | Execute SQL |
| `schema()` | Full schema catalog (`OrderedTable[string, JsonNode]`) |
| `schemaFor(table)` | Single-table descriptor |
| `setHistoryRetentionEpochs(epochs)` | Set the history retention window |
| `historyRetentionEpochs()` | Get the current retention window |
| `earliestRetainedEpoch()` | Get the oldest readable epoch |
| `begin()` | Start a batch |

### `Column`

`Column` describes one column in a `createTable` call. `id` is the stable
on-wire identifier referenced everywhere else.

| Field | Type | Description |
|-------|------|-------------|
| `id` | `int64` | Stable on-wire column identifier |
| `name` | `string` | Human-readable name |
| `ty` | `string` | Engine type, e.g. `int64`, `varchar`, `float64` |
| `primaryKey` | `bool` | Marks the column as the primary key |
| `nullable` | `bool` | Allows NULL values |
| `enumVariants` | `seq[string]` | Allowed values for an enum column; emitted as `enum_variants` only when non-empty |
| `defaultValue` | `Option[string]` | Server-side default; emitted as `default_value` only when set |
| `defaultValueJson` | `Option[JsonNode]` | Static JSON scalar; takes precedence over `defaultValue` |
| `defaultExpr` | `Option[string]` | Dynamic default: `now` or `uuid`; takes precedence server-side |

```nim
import std/options
Column(id: 4'i64, name: "status", ty: "varchar",
       enumVariants: @["pending", "paid", "shipped"])
Column(id: 5'i64, name: "note", ty: "varchar", nullable: true,
       defaultValue: some(""))
```

### `QueryBuilder`

| Method | Description |
|--------|-------------|
| `where(type, params)` | Add a native condition (AND-ed) |
| `projection(columnIDs)` | Set column projection |
| `limit(n)` | Set row limit |
| `offset(n)` | Skip matching rows before the limit |
| `build()` | Build the request payload |
| `execute()` | Run the query |
| `truncated` | Whether the last `execute` result hit the limit |

### `Transaction`

| Method | Description |
|--------|-------------|
| `put(table, cells, returning)` | Stage an insert |
| `delete(table, rowId)` | Stage a delete by row id |
| `deleteByPk(table, pk)` | Stage a delete by primary key |
| `count` | Number of staged operations |
| `commit(idempotencyKey = "")` | Commit atomically |
| `rollback()` | Discard all operations |

### Errors

| Type | HTTP status | Meaning |
|-------|-------------|---------|
| `MongrelDBError` | - | Base type for every client failure |
| `AuthError` | 401, 403 | Bad or missing credentials |
| `NotFoundError` | 404 | Missing table, schema, or resource |
| `ConflictError` | 409 | Unique/FK/check/trigger violation |
| `QueryError` | 400, 5xx, transport | Catch-all for malformed queries and server errors |

All carry `.status` (int), `.code` (string, e.g. `UNIQUE_VIOLATION`), and
`.opIndex` (int, the offending op in a failed transaction, or -1).

## Building and testing

The live test suite is a standalone executable that boots a real
`mongreldb-server` daemon and exercises the full client surface. It resolves
the binary in this order: the `MONGRELDB_SERVER` env var, `./bin/mongreldb-server`,
then `mongreldb-server` on `PATH`. If none is available and `MONGRELDB_URL` is
unset, it self-skips. Set `MONGRELDB_URL` to point at an already-running daemon.

```sh
# Validate the package manifest and compile the library module
nimble check
nim c --path:src --noLinking:on src/mongreldb.nim

# Run the offline unit tests (no daemon needed)
nim c --path:src --run tests/test_query.nim

# Build and run the live suite
nimble liveTest
# or, explicitly:
# nim c --path:src --mm:orc -o:build/live_test src/mongreldb/tests/live_test.nim
# ./build/live_test   # set MONGRELDB_URL=http://127.0.0.1:8453 to use a running daemon
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.57.0/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the client dependency-free (Nim standard library only) and free of engine C ABI bindings.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
