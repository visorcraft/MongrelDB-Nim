# Quickstart

Zero to a running MongrelDB Nim program in fifteen minutes. This guide assumes
a fresh machine and walks through installing the prerequisites, starting the
daemon, and writing, running, and understanding a complete program.

---

## 1. Prerequisites

You need two things installed: the Nim toolchain and a `mongreldb-server`
daemon.

### Install Nim 2.0 or newer

Verify it:

```sh
nim --version
# Nim Compiler Version 2.x ...
```

If you do not have it, install from <https://nim-lang.org/install.html> or your
package manager (e.g. `pacman -S nim`, `brew install nim`). The Nimble package
manager ships with the compiler.

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.46.1/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the current working directory.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and pull in the client

```sh
nimble install mongreldb
```

For a local project, init a Nimble package and add the dependency:

```sh
mkdir demo && cd demo
nimble init
```

Then add `mongreldb` to the `requires` list in your `.nimble` file:

```nim
requires "nim >= 2.0", "mongreldb"
```

If you are vendoring the source locally instead, use a path dependency:

```nim
requires "mongreldb#head"
# or set the path explicitly when compiling:
#   nim c --path:../mongreldb_nim/src demo.nim
```

## 4. Write your first program

Create `demo.nim`:

```nim
import std/json
import mongreldb

# 1. Connect to the daemon. Empty URL falls back to http://127.0.0.1:8453.
let db = newMongrelDB("http://127.0.0.1:8453")

# 2. Health check before doing anything else.
if not db.health():
  echo "daemon not reachable"
  quit(1)

# 3. Create a table. Each Column has a stable numeric id, a name, a type, and
#    flags. The first column is the primary key.
let tid = db.createTable("orders", [
  Column(id: 1'i64, name: "id",       ty: "int64",   primaryKey: true,  nullable: false),
  Column(id: 2'i64, name: "customer", ty: "varchar", primaryKey: false, nullable: false),
  Column(id: 3'i64, name: "amount",   ty: "float64", primaryKey: false, nullable: false),
])
echo "created table id: ", tid

# 4. Insert rows. Cells are (column_id, JsonNode) pairs. put() is a one-op
#    transaction; the optional third argument is an idempotency key.
discard db.put("orders", {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %99.50})
discard db.put("orders", {1'i64: %2'i64, 2'i64: %"Bob",   3'i64: %150.00})

# 5. Query with a native index condition. The range index serves this in
#    sub-millisecond. projection() selects only column ids 1 and 2.
let q = db.query("orders")
    .where("range", parseJson("""{"column": 3, "min": 100.0}"""))
    .projection([1'i64, 2'i64])
    .limit(100)
let rows = q.execute()
for row in rows:
  echo "row: ", row

# 6. Count the rows.
echo "total rows: ", db.count("orders")
```

Run it:

```sh
nim c --run demo.nim
```

You should see:

```
created table id: 1
row: {"1":2,"2":"Bob"}
total rows: 2
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `newMongrelDB(url)` | Builds an HTTP client targeting one daemon. Safe to share across threads once constructed. |
| `db.health()` | GET `/health`; returns `true` when the daemon answers. Always check before real work. |
| `db.createTable(name, cols)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. |
| `db.put(table, cells)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `db.query(table).where(...)` | Builds a `/kit/query` body. `where` pushes a condition down to a native index. |
| `.projection([1'i64, 2'i64])` | Server returns only those column ids, saving bandwidth. |
| `.limit(100)` | Caps the result; check `q.truncated` afterward to detect overflow. |
| `.execute()` | Sends the query and decodes the `rows` array. |
| `db.count(table)` | GET `/tables/{name}/count`. |

## 6. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `createTable`, never the `name`. The query builder's
`column` alias maps to the server's `column_id` - pass the integer id, not the
string name:

```nim
# Wrong:
.where("range", parseJson("""{"column": "amount", "min": 100.0}"""))
# Right:
.where("range", parseJson("""{"column": 3, "min": 100.0}"""))
```

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as a `ConflictError`
(HTTP 409), not as a silent no-op.

**Calling `commit` twice on the same `Transaction`.** The second call raises
`ValueError: mongreldb: transaction already committed`. Create a fresh
`db.begin()` for each logical unit of work.

**Reusing a `QueryBuilder` and expecting a fresh `truncated`.** `truncated`
reflects the most recent `execute()`. Build a new query, or re-run
`execute()` before reading it.

**Expecting `sql` to always return rows.** The `/sql` endpoint streams Arrow
IPC for `SELECT` in most builds, so `sql` returns an empty seq (not an error)
for result sets. Use it for DDL/DML and statements whose success is the
signal; use the native query builder for typed row retrieval.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call raises `AuthError` unless you
pass `token =` or `username =`/`password =` to `newMongrelDB`. See
[auth.md](auth.md).

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full exception hierarchy and recovery patterns
