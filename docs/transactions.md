# Batch Transactions

A `Transaction` stages operations locally and commits them atomically in a
single `/kit/txn` request. The daemon enforces unique, foreign-key, check, and
trigger constraints at commit time; on any violation every staged op rolls
back and `commit` raises a `ConflictError` carrying the server's structured
error code and the offending op index.

This guide covers building a batch, committing atomically, idempotency keys,
and safe retries.

```nim
import std/json
import mongreldb
```

---

## Start a transaction

`db.begin()` returns a fresh, single-use `Transaction`:

```nim
let db = newMongrelDB("http://127.0.0.1:8453")
let txn = db.begin()
```

## Stage operations

Each builder method returns the transaction so calls chain. Nothing is sent
until `commit`:

```nim
# Insert (returning=false means the result does not echo the row).
discard txn.put("orders", {1'i64: %10'i64, 2'i64: %"Dave", 3'i64: %50.00})
discard txn.put("orders", {1'i64: %11'i64, 2'i64: %"Eve",  3'i64: %75.00})

# Delete by primary-key value.
discard txn.deleteByPk("orders", %2'i64)

# Delete by the internal row id (the engine's storage row number, not the
# primary key).
discard txn.delete("orders", 7'i64)
```

`put(table, cells, returning)` stages an insert. Set `returning = true` to ask
the daemon to echo the written row back in the per-operation result — useful
when you want server-generated values without a second round trip.

`count` reports how many ops are staged:

```nim
echo "staged: ", txn.count() # 3
```

## Commit atomically

`commit()` sends every staged op in one request. Either all apply or none do:

```nim
try:
  let results = txn.commit()
  echo "committed ", results.len, " results"
except ConflictError as e:
  # A constraint violation rolled back the whole batch.
  echo "conflict: ", e.msg, " code=", e.code, " op=", e.opIndex
```

The server's results array has one entry per staged op, in order. Each entry
is a `JsonNode`; its shape depends on the op and the `returning` flag.

## Idempotency keys

`commit(idempotencyKey)` makes the commit safe to retry. Pass a stable, unique
key — the daemon stores it and returns the original response on duplicate
commits, even across daemon restarts:

```nim
let txn = db.begin()
discard txn.put("orders", {1'i64: %20'i64, 2'i64: %"Frank", 3'i64: %100.00})

# If this call times out or the network drops, replaying the same ops under
# the same key is safe — the daemon deduplicates.
discard txn.commit("order-20-create")
```

A good idempotency key is:

- **Unique per logical operation.** Reusing a key for a different batch makes
  the second one a no-op (the server replays the first result).
- **Stable across retries.** Generate it once and hold it for the lifetime of
  the attempt.
- **Opaque.** The server stores it as a string; any encoding works (UUID,
  composite key, hash).

## Single-use transactions

A `Transaction` is single-use. After `commit` or `rollback`, any further call
raises `ValueError("mongreldb: transaction already committed")`. Start a new
`db.begin()` for each logical unit of work:

```nim
let txn = db.begin()
discard txn.commit()

# reuse is an error:
# discard txn.put("orders", {1'i64: %99'i64})
#     -> ValueError: mongreldb: transaction already committed

let next = db.begin()
discard next.commit()
```

## Rollback

`rollback()` discards all staged operations without contacting the daemon.
Like `commit`, it finalizes the transaction:

```nim
let txn = db.begin()
discard txn.put("orders", {1'i64: %1'i64})

if someCondition:
  txn.rollback() # nothing sent to the server
  return
discard txn.commit()
```

## Single-op convenience

For one row, `db.put(table, cells, idempotencyKey)` is a one-op transaction
under the hood. It exists for ergonomics; batch real multi-op work in a
`Transaction` to get atomicity and a single round trip:

```nim
# Equivalent to a Transaction with one put, committed immediately.
discard db.put("orders", {1'i64: %1'i64, 2'i64: %"Alice"}, "order-1-create")
```

## Retry pattern

Combine an idempotency key with a retry loop to ride out transient failures.
Only retry on transport failures (`QueryError` with `status == -1`) or
explicit 5xx; treat `ConflictError` as a data problem to fix, not a transient
one:

```nim
proc commitWithRetry(txn: Transaction; key: string): seq[JsonNode] =
  for attempt in 0 ..< 3:
    try:
      return txn.commit(key)
    except ConflictError:
      raise # constraint violation — do NOT retry blindly
    except QueryError as e:
      if e.status == -1 or (e.status >= 500 and e.status < 600):
        sleep(100) # transport or server error — safe to retry
        continue
      raise
  raise newException(IOError, "commit failed after 3 attempts")
```

Because each attempt uses the same idempotency key, a retry that lands after
the daemon already applied the batch returns the original result instead of
applying the ops twice.

## Common pitfalls

**Forgetting the idempotency key on retries.** Without it, a retry after a
network timeout can double-apply the batch. Always pair retries with a stable
key.

**Committing the same `Transaction` from two threads.** The transaction object
is a `ref`, not synchronized. Stage and commit from one flow of control.

**Expecting per-op atomicity.** The atomicity unit is the whole batch. A
single bad op rolls back the good ones too — that is the point. Validate data
before staging if you want to avoid the round trip.

**Swallowing `ConflictError`.** The `.code` and `.opIndex` fields tell you
exactly what went wrong and where. Log them; they are the difference between a
quick fix and a guessing game.

## Next steps

- [queries.md](queries.md) — read patterns
- [errors.md](errors.md) — the full exception hierarchy
- [sql.md](sql.md) — when to choose SQL over the typed API
