## Offline unit tests for the mongreldb Nim client.
##
## These run without a daemon. They cover the pure-logic helpers: the query
## builder's condition-alias normalization and URL path escaping.

import std/json
import mongreldb, mongreldb/query

proc main() =
  var failed = 0

  template check(cond: bool; msg: string) =
    if not cond:
      stderr.writeLine("FAIL: ", msg)
      inc failed

  # Alias normalization for an FTS condition: value -> pattern, column ->
  # column_id.
  let params = parseJson("""{"column": 2, "value": "database performance"}""")
  let norm = normalizeCondition("fm_contains", params)
  check(norm["pattern"].getStr() == "database performance",
      "fm_contains value -> pattern")
  check(norm["column_id"].getInt() == 2, "column -> column_id")

  # For a pk condition, value stays value.
  let pkParams = parseJson("""{"value": 42}""")
  let pkNorm = normalizeCondition("pk", pkParams)
  check(pkNorm["value"].getInt() == 42, "pk value stays value")

  # min/max -> lo/hi
  let rangeParams = parseJson("""{"column": 3, "min": 100, "max": 150}""")
  let rangeNorm = normalizeCondition("range", rangeParams)
  check(rangeNorm.hasKey("lo") and rangeNorm["lo"].getInt() == 100,
      "min -> lo")
  check(rangeNorm.hasKey("hi") and rangeNorm["hi"].getInt() == 150,
      "max -> hi")
  check(rangeNorm["column_id"].getInt() == 3, "range column -> column_id")

  # URL path escape: only RFC 3986 unreserved chars pass through; '/' is
  # encoded so it cannot inject an extra path segment.
  check(urlPathEscape("orders") == "orders", "escape leaves safe string")
  check(urlPathEscape("a/b") == "a%2Fb", "escape encodes slash")
  check(urlPathEscape("a b") == "a%20b", "escape encodes space")

  if failed == 0:
    echo "all offline unit tests passed"
  else:
    echo "failed=", failed
    quit(1)

when isMainModule:
  main()
