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

    var scalar = Column(name: "attempts", ty: "int64",
      defaultValue: some("legacy"), defaultValueJson: some(%3))
    let scalarWire = $columnToJsonNode(scalar)
    check scalarWire.contains("\"default_value\":3")
    scalar.defaultExpr = some("uuid")
    let exprWire = $columnToJsonNode(scalar)
    check exprWire.contains("\"default_expr\":\"uuid\"")
    check(not exprWire.contains("default_value"))
    check ($columnToJsonNode(Column(id: 5, name: "s", ty: "varchar", defaultValueJson: some(%"draft")))).contains("\"default_value\":\"draft\"")
    check ($columnToJsonNode(Column(id: 6, name: "b", ty: "bool", defaultValueJson: some(%true)))).contains("\"default_value\":true")
    check ($columnToJsonNode(Column(id: 7, name: "n", ty: "varchar", defaultValueJson: some(newJNull())))).contains("\"default_value\":null")

  test "enum_variants and default_value are absent when unset":
    var col = Column(
      name: "plain",
      ty: "int64",
    )
    let wire = $columnToJsonNode(col)
    check(not wire.contains("enum_variants"))
    check(not wire.contains("default_value"))

  test "history retention payload uses the exact frozen key":
    let body = $(%*{"history_retention_epochs": 42})
    check body.contains("\"history_retention_epochs\"")
    check body.contains("\"history_retention_epochs\":42")
