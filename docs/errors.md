# Error Handling

Every non-2xx response is mapped to a typed exception. Catch `MongrelDBError`
for any failure, or one of the specific subclasses to discriminate by category.

```nim
import mongreldb
```

## The exception hierarchy

All client exceptions descend from `MongrelDBError`, which itself descends
from Nim's `CatchableError`:

```
CatchableError
└── MongrelDBError
    ├── AuthError
    ├── NotFoundError
    ├── ConflictError
    └── QueryError
```

| Type                | HTTP status         | Meaning |
|---------------------|---------------------|---------|
| `MongrelDBError`    | —                   | Base type for every client failure. Catch this to handle any error. |
| `AuthError`         | 401, 403            | Bad or missing credentials. |
| `NotFoundError`     | 404                 | Missing table, schema, or resource. |
| `ConflictError`     | 409                 | Unique / foreign-key / check / trigger violation rolled back a transaction. |
| `QueryError`        | 400, 5xx, transport | Catch-all for malformed queries, server errors, and transport failures (status `-1`). |

Every `MongrelDBError` carries three fields beyond `msg`:

| Field      | Type    | Meaning |
|------------|---------|---------|
| `.status`  | `int`   | HTTP status code from the daemon, or `-1` when unknown (e.g. a transport failure). |
| `.code`    | `string`| The server's structured error code, when present (e.g. `UNIQUE_VIOLATION`). |
| `.opIndex` | `int`   | The offending op index within a failed transaction, or `-1`. |

## Catching by type

Match the specific subclass first, then fall back to the base:

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

Nim evaluates `except` clauses in order, so list subclasses before their base
types.

## Transaction conflicts

A `Transaction.commit` runs all staged ops in a single atomic batch. If any
op violates a unique, foreign-key, check, or trigger constraint, the daemon
rolls back the entire batch and returns HTTP 409, which the client surfaces
as `ConflictError`:

```nim
let txn = db.begin()
discard txn.put("orders", {1'i64: %10'i64, 2'i64: %"Dave"})

try:
  discard txn.commit()
except ConflictError as e:
  echo "batch rolled back: ", e.code, " op=", e.opIndex
  # e.code might be "UNIQUE_VIOLATION"; e.opIndex is the offending op index.
```

The `.code` and `.opIndex` fields tell you exactly which op tripped which
constraint. Fix that op, then retry with a fresh transaction.

## Single-use transactions

`Transaction.commit` and `Transaction.rollback` both flip an internal flag.
Calling either method on the transaction afterward raises a plain `ValueError`
with the message `"mongreldb: transaction already committed"`. This is a
programming error, not a server failure, so it is not a `MongrelDBError`. Start
a new transaction for each batch:

```nim
let txn = db.begin()
discard txn.commit()

# reuse is an error:
# discard txn.put("orders", {1'i64: %99'i64})
#     -> ValueError: mongreldb: transaction already committed

let next = db.begin()
discard next.commit()
```

## Retries and idempotency

Network glitches and daemon restarts happen. Pair an idempotency key with a
retry loop for commit:

```nim
proc commitWithRetry(txn: Transaction; key: string): seq[JsonNode] =
  for attempt in 0 ..< 3:
    try:
      return txn.commit(key)
    except ConflictError:
      raise # constraint violation — fix the data, do not retry blindly
    except QueryError as e:
      if e.status == -1 or (e.status >= 500 and e.status < 600):
        sleep(100) # transport or server error — safe to retry
        continue
      raise
  raise newException(IOError, "commit failed after 3 attempts")
```

Only retry on transport failures (`status == -1`) or explicit 5xx with the
same idempotency key. `ConflictError` and `QueryError` with a 4xx status
indicate a problem with the request itself and must be fixed before retrying.

Because each attempt uses the same idempotency key, a retry that lands after
the daemon already applied the batch returns the original result instead of
applying the ops twice.

## The health check never raises

`db.health()` deliberately swallows errors and returns `false`. Use it for
liveness probes where an exception would be noise; use the real methods when
you want to know what went wrong:

```nim
if not db.health():
  echo "daemon down — check the URL and auth"
```

## Common pitfalls

**Catching `Exception` too broadly.** A bare `except Exception` will also
catch the single-use-transaction `ValueError` and any unrelated stdlib
exception. Catch `MongrelDBError` (or a subclass) when you mean to handle a
client error.

**Retrying `ConflictError`.** A conflict means the batch violated a
constraint; replaying the same ops will fail the same way. Fix the offending
op, then retry.

**Forgetting the single-use contract.** A transaction is single-use. If you
share one across function boundaries, make it obvious who calls `commit` or
`rollback`.

**Ignoring `.code` and `.opIndex`.** On a `ConflictError`, these pinpoint the
failure. Log them; they are the difference between a quick fix and a guessing
game.

## Next steps

- [transactions.md](transactions.md) — atomic batches and idempotency
- [auth.md](auth.md) — where `AuthError` comes from
