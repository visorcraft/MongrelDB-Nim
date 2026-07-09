## Example: basic CRUD operations with the MongrelDB Nim client.
##
## Run (from a project with mongreldb as a Nimble dependency):
##
##   nim c --run examples/basic_crud.nim
##
## Or compile against the vendored source:
##
##   nim c --path:../src --run examples/basic_crud.nim
##
## Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
##
## Creates a table, inserts three rows, counts them, queries all rows, "updates"
## one row by overwriting it at its primary key, deletes one row, then drops
## the table. Progress is printed at every step.

import std/json
import mongreldb

const
  url = "http://127.0.0.1:8453"
  table = "example_crud"

let db = newMongrelDB(url)

# Health check; bail out if the daemon is unreachable.
if not db.health():
  stderr.writeLine("daemon not reachable at ", url)
  quit(1)
echo "Connected to MongrelDB"

# Create the table. Schema: id (int64 PK), name (varchar), score (float64).
let tid = db.createTable(table, [
  Column(id: 1'i64, name: "id", ty: "int64", primaryKey: true, nullable: false),
  Column(id: 2'i64, name: "name", ty: "varchar", primaryKey: false, nullable: false),
  Column(id: 3'i64, name: "score", ty: "float64", primaryKey: false, nullable: false),
])
echo "Created table ", table, " (id ", tid, ")"

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

# Update Alice's score by re-putting the same primary key with new values. The
# PK is the row identity, so a put to an existing PK overwrites it.
discard db.put(table, {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %100.0})
echo "Updated Alice's score to 100.0"
echo "Total rows after update: ", db.count(table)

# Delete Carol (primary key 3).
db.deleteByPk(table, %3'i64)
echo "Deleted Carol; remaining rows: ", db.count(table)

# Cleanup.
db.dropTable(table)
echo "Dropped table ", table
