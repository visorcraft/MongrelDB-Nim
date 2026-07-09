## Example: atomic batch transactions with the MongrelDB Nim client.
##
## Run (from a project with mongreldb as a Nimble dependency):
##
##   nim c --path:src --run examples/transactions.nim
##
## Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
##
## Creates a table, stages three inserts in a single transaction, commits them
## atomically, verifies the count, then demonstrates idempotent retries by
## re-committing with the same idempotency key (the daemon returns the original
## result and applies no duplicate rows). Cleans up by dropping the table.

import std/[json, strutils, times]
import mongreldb

proc main() =
  const url = "http://127.0.0.1:8453"

  # A per-run unique suffix keeps every invocation isolated on a shared daemon.
  let table = "example_txn_" & intToStr(getTime().toUnix())

  # Idempotency keys must be unique per run: a reused key replays the original
  # result and silently drops the new batch, so a hardcoded key would make every
  # run after the first a no-op.
  let txnKey = "example-txn-key-" & intToStr(getTime().toUnix())

  let db = newMongrelDB(url)

  if not db.health():
    stderr.writeLine("daemon not reachable at ", url)
    quit(1)
  echo "Connected to MongrelDB"

  discard db.createTable(table, [
    Column(id: 1'i64, name: "id", ty: "int64", primaryKey: true, nullable: false),
    Column(id: 2'i64, name: "name", ty: "varchar", primaryKey: false, nullable: false),
    Column(id: 3'i64, name: "score", ty: "float64", primaryKey: false, nullable: false),
  ])
  echo "Created table ", table

  # Guaranteed cleanup: drop the table on success or error.
  defer:
    try:
      db.dropTable(table)
    except:
      discard

  try:
    # Stage three puts and commit them atomically. Either every op lands or none
    # do; a constraint violation rolls back the whole batch.
    var txn = db.begin()
    discard txn.put(table, {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %95.5})
    discard txn.put(table, {1'i64: %2'i64, 2'i64: %"Bob", 3'i64: %82.0})
    discard txn.put(table, {1'i64: %3'i64, 2'i64: %"Carol", 3'i64: %78.3})
    echo "Staged ", txn.count(), " operations"

    let results = txn.commit()
    echo "Committed atomically: ", results.len, " operations applied"

    echo "Verified row count after commit: ", db.count(table)

    # Idempotent retry: stage the same batch again with an idempotency key, then
    # commit a second time with the SAME key. The daemon replays the original
    # result and applies no extra rows.
    var retry = db.begin()
    discard retry.put(table, {1'i64: %4'i64, 2'i64: %"Dave", 3'i64: %60.0})
    discard retry.commit(idempotencyKey = txnKey)
    echo "After first idempotent commit: ", db.count(table), " rows"

    var retry2 = db.begin()
    discard retry2.put(table, {1'i64: %4'i64, 2'i64: %"Dave", 3'i64: %60.0})
    discard retry2.commit(idempotencyKey = txnKey)
    echo "After duplicate idempotent commit (same key): ", db.count(table), " rows (no double-apply)"
  finally:
    echo "Dropped table ", table

main()
