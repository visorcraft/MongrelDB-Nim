## Wire-shape regression tests for `Column` serialization.
##
## Pure offline tests - no daemon required. They pin down the JSON envelope
## produced by `columnToJsonNode`, in particular that the two new optional
## fields (`enumVariants`, `defaultValue`) round-trip with their wire names
## (`enum_variants`, `default_value`) when populated and are omitted entirely
## when unset.

import std/[json, options, strutils, unittest]
import mongreldb

suite "Column wire shape":
  test "enum_variants and default_value appear when populated":
    var col = Column(
      name: "status",
      ty: "enum",
      enumVariants: @["a", "b", "c"],
    )
    let createdAt = Column(
      name: "created_at",
      ty: "timestamp_nanos",
      defaultValue: some("now"),
    )
    let constraints = %*{
      "checks": [{
        "id": 1,
        "name": "id_present",
        "expr": {"IsNotNull": 1},
      }],
    }
    let wire = $createTablePayload("events", [col, createdAt], constraints)
    check wire.contains("\"enum_variants\":[\"a\",\"b\",\"c\"]")
    check wire.contains("\"default_value\":\"now\"")
    check wire.contains("\"constraints\":{")
    check wire.contains("\"checks\":[")
    check wire.contains("\"IsNotNull\":1")

  test "enum_variants and default_value are absent when unset":
    var col = Column(
      name: "plain",
      ty: "int64",
    )
    let wire = $columnToJsonNode(col)
    check(not wire.contains("enum_variants"))
    check(not wire.contains("default_value"))
