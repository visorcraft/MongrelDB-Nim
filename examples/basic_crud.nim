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
## Creates a table with an enum-constrained status column and a nullable note
## column that carries a server-side default, inserts three rows (one of which
## omits `note` so the default kicks in), counts them, queries all rows,
## upserts (updates) one row by primary key, deletes one row, then drops the
## table. Progress is printed at every step.

import std/[json, options, strutils, times]
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

  # Create the table. Schema: id (int64 PK), name (varchar), score (float64),
  # status (varchar constrained to a small set of enum variants), and note
  # (nullable varchar with a server-side default of "n/a").
  #
  # `enumVariants` declares the allowed values for `status`. The engine
  # validates every write against the list; an unknown variant surfaces as a
  # ConflictError. The list is omitted from the request JSON when empty.
  #
  # `defaultValue` is a server-side default: when a put omits the column, the
  # engine fills it in with this value. `Option[string]` keeps the wire key
  # (`default_value`) absent unless explicitly set.
  discard db.createTable(table, [
    Column(id: 1'i64, name: "id",     ty: "int64",   primaryKey: true,  nullable: false),
    Column(id: 2'i64, name: "name",   ty: "varchar", primaryKey: false, nullable: false),
    Column(id: 3'i64, name: "score",  ty: "float64", primaryKey: false, nullable: false),
    Column(id: 4'i64, name: "status", ty: "varchar", primaryKey: false, nullable: false,
           enumVariants: @["active", "inactive", "banned"]),
    Column(id: 5'i64, name: "note",   ty: "varchar", primaryKey: false, nullable: true,
           defaultValue: some("n/a")),
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
    # Insert three rows. Cells are (column_id, JsonNode) pairs. The `note`
    # column has a server-side default; omitting it in the first and third
    # puts lets the engine backfill "n/a". The second put supplies a value to
    # show that an explicit write overrides the default. Every `status` value
    # is one of the enum variants declared on the column.
    discard db.put(table, {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %95.5, 4'i64: %"active"})
    discard db.put(table, {1'i64: %2'i64, 2'i64: %"Bob",   3'i64: %82.0, 4'i64: %"active", 5'i64: %"VIP"})
    discard db.put(table, {1'i64: %3'i64, 2'i64: %"Carol", 3'i64: %78.3, 4'i64: %"inactive"})
    echo "Inserted 3 rows"

    echo "Total rows: ", db.count(table)

    # Query all rows (no conditions). The default-filled `note` comes back as
    # "n/a" on Alice and Carol; Bob's explicit "VIP" is preserved.
    let all = db.query(table).execute()
    echo "Query returned ", all.len, " rows:"
    for row in all:
      echo "  ", row

    # Update Alice's score with an upsert. A second `put` to an existing primary
    # key would 409 (UNIQUE_VIOLATION); upsert writes `updateCells` on a PK
    # conflict instead. The insert values are the PK + new values, and
    # updateCells carries the non-key columns to overwrite.
    discard db.upsert(table,
      {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %100.0, 4'i64: %"active"},
      {3'i64: %100.0, 4'i64: %"active"})
    echo "Upserted Alice's score to 100.0"
    echo "Total rows after upsert: ", db.count(table)

    # Delete Carol (primary key 3).
    db.deleteByPk(table, %3'i64)
    echo "Deleted Carol; remaining rows: ", db.count(table)
  finally:
    echo "Dropped table ", table

main()
