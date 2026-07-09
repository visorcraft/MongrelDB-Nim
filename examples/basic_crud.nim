## Example: basic CRUD operations with the MongrelDB Nim client.
##
## Run (from a project with mongreldb as a Nimble dependency):
##
##   nim c --path:src --run examples/basic_crud.nim
##
## Or compile against the vendored source:
##
##   nim c --path:../src --run examples/basic_crud.nim
##
## Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
##
## Creates a table, inserts three rows, counts them, queries all rows,
## upserts (updates) one row by primary key, deletes one row, then drops
## the table. Progress is printed at every step.

import std/[json, strutils, times]
import mongreldb

proc main() =
  const url = "http://127.0.0.1:8453"

  # A per-run unique suffix keeps every invocation isolated on a shared daemon
  # (a fresh name never collides with a prior, possibly failed run).
  let table = "example_crud_" & intToStr(getTime().toUnix())

  let db = newMongrelDB(url)

  # Health check; bail out if the daemon is unreachable.
  if not db.health():
    stderr.writeLine("daemon not reachable at ", url)
    quit(1)
  echo "Connected to MongrelDB"

  # Create the table. Schema: id (int64 PK), name (varchar), score (float64).
  discard db.createTable(table, [
    Column(id: 1'i64, name: "id", ty: "int64", primaryKey: true, nullable: false),
    Column(id: 2'i64, name: "name", ty: "varchar", primaryKey: false, nullable: false),
    Column(id: 3'i64, name: "score", ty: "float64", primaryKey: false, nullable: false),
  ])
  echo "Created table ", table

  # Guaranteed cleanup: drop the table no matter how the body exits (success or
  # raised exception), so a failed run never leaves a dangling table behind.
  defer:
    try:
      db.dropTable(table)
    except:
      discard

  try:
    # Insert three rows. Cells are (column_id, JsonNode) pairs.
    discard db.put(table, {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %95.5})
    discard db.put(table, {1'i64: %2'i64, 2'i64: %"Bob", 3'i64: %82.0})
    discard db.put(table, {1'i64: %3'i64, 2'i64: %"Carol", 3'i64: %78.3})
    echo "Inserted 3 rows"

    echo "Total rows: ", db.count(table)

    # Query all rows (no conditions).
    let all = db.query(table).execute()
    echo "Query returned ", all.len, " rows:"
    for row in all:
      echo "  ", row

    # Update Alice's score with an upsert. A second `put` to an existing primary
    # key would 409 (UNIQUE_VIOLATION); upsert writes `updateCells` on a PK
    # conflict instead. The insert values are the PK + new values, and
    # updateCells carries the non-key columns to overwrite.
    discard db.upsert(table,
      {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %100.0},
      {2'i64: %"Alice", 3'i64: %100.0})
    echo "Upserted Alice's score to 100.0"
    echo "Total rows after upsert: ", db.count(table)

    # Delete Carol (primary key 3).
    db.deleteByPk(table, %3'i64)
    echo "Deleted Carol; remaining rows: ", db.count(table)
  finally:
    echo "Dropped table ", table

main()
