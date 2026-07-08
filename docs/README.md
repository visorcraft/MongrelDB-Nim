# MongrelDB Nim Documentation

End-to-end guides for the pure-Nim MongrelDB client. Each guide is
self-contained and uses idiomatic Nim (standard library only, no external
dependencies).

| Guide | What you'll learn |
|-------|-------------------|
| [Quickstart](quickstart.md) | Install Nim and the daemon, write and run a complete program. |
| [Batch transactions](transactions.md) | Atomic multi-op commits, idempotency keys, and safe retries. |
| [Native query builder](queries.md) | Every native index condition and the alias translation rules. |
| [SQL](sql.md) | Recursive CTEs, window functions, `CREATE TABLE AS SELECT`. |
| [Authentication](auth.md) | Bearer token, HTTP Basic, and user/role management via SQL. |
| [Error handling](errors.md) | The exception hierarchy and recovery patterns. |

The Nim client talks HTTP/JSON to a running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB)
daemon. If you have not already, start with the [Quickstart](quickstart.md).
