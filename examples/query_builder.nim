## Example: query builder conditions with the MongrelDB Nim client.
##
## Run (from a project with mongreldb as a Nimble dependency):
##
##   nim c --run examples/query_builder.nim
##
## Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
##
## Creates a table, inserts five rows with varying scores, then uses the native
## query builder to fetch rows by a range condition and by an exact primary-key
## match. Cleans up by dropping the table.

import std/json
import mongreldb

const
  url = "http://127.0.0.1:8453"
  table = "example_query"

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

# Five rows with varying scores.
discard db.put(table, {1'i64: %1'i64, 2'i64: %"Alice", 3'i64: %40.0})
discard db.put(table, {1'i64: %2'i64, 2'i64: %"Bob", 3'i64: %65.0})
discard db.put(table, {1'i64: %3'i64, 2'i64: %"Carol", 3'i64: %82.0})
discard db.put(table, {1'i64: %4'i64, 2'i64: %"Dave", 3'i64: %91.0})
discard db.put(table, {1'i64: %5'i64, 2'i64: %"Eve", 3'i64: %12.5})
echo "Inserted 5 rows"

# Range condition: scores in [60.0, 90.0]. The "column" alias maps to the
# server's column_id; pass the numeric column id (3), not the name. The "score"
# column is float64, so use the range_f64 condition (plain "range" expects an
# i64 bound and rejects floating-point values). range_f64 also requires the
# inclusivity flags (min_inclusive/max_inclusive -> lo_inclusive/hi_inclusive).
let rng = db.query(table)
    .where("range_f64", parseJson("""{"column": 3, "min": 60.0, "max": 90.0, "min_inclusive": true, "max_inclusive": true}"""))
    .execute()
echo "Range query (score in [60,90]) returned ", rng.len, " rows:"
for row in rng:
  echo "  ", row

# Primary-key condition: fetch the single row with id == 4.
let pk = db.query(table)
    .where("pk", parseJson("""{"value": 4}"""))
    .execute()
echo "PK query (id == 4) returned ", pk.len, " rows:"
for row in pk:
  echo "  ", row

db.dropTable(table)
echo "Dropped table ", table
