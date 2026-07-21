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
    let scalarNode = columnToJsonNode(scalar)
    check scalarNode["default_value"].kind == JInt
    check scalarNode["default_value"].getInt() == 3

    scalar.defaultExpr = some("now")
    let exprNode = columnToJsonNode(scalar)
    check exprNode["default_expr"].kind == JString
    check exprNode["default_expr"].getStr() == "now"
    check(not exprNode.hasKey("default_value"))

    let strNode = columnToJsonNode(Column(id: 5, name: "s", ty: "varchar",
      defaultValueJson: some(%"draft")))
    check strNode["default_value"].kind == JString
    check strNode["default_value"].getStr() == "draft"

    let intNode = columnToJsonNode(Column(id: 6, name: "n", ty: "int64",
      defaultValueJson: some(%7)))
    check intNode["default_value"].kind == JInt
    check intNode["default_value"].getInt() == 7

    let boolNode = columnToJsonNode(Column(id: 7, name: "b", ty: "bool",
      defaultValueJson: some(%true)))
    check boolNode["default_value"].kind == JBool
    check boolNode["default_value"].getBool() == true

    let nullNode = columnToJsonNode(Column(id: 8, name: "x", ty: "varchar",
      defaultValueJson: some(newJNull())))
    check nullNode["default_value"].kind == JNull

  test "enum_variants and default_value are absent when unset":
    var col = Column(
      name: "plain",
      ty: "int64",
    )
    let wire = $columnToJsonNode(col)
    check(not wire.contains("enum_variants"))
    check(not wire.contains("default_value"))

  test "all index kinds and embedding source reach create_table":
    let embedding = Column(
      id: 2,
      name: "embedding",
      ty: "embedding(384)",
      embeddingSource: some(%*{
        "kind": "configured_model",
        "provider_id": "docs",
        "model_id": "model",
        "model_version": "1",
      }),
    )
    let indexes = %*[
      {"name": "bm", "column_id": 1, "kind": "bitmap"},
      {"name": "fm", "column_id": 1, "kind": "fm_index"},
      {"name": "ann", "column_id": 2, "kind": "ann",
       "predicate": "embedding IS NOT NULL",
       "options": {"ann": {"m": 24, "ef_construction": 96,
                              "ef_search": 48, "quantization": "dense"}}},
      {"name": "range", "column_id": 1, "kind": "learned_range"},
      {"name": "minhash", "column_id": 1, "kind": "minhash"},
      {"name": "sparse", "column_id": 1, "kind": "sparse"},
    ]
    let wire = $createTablePayload("search_docs", [
      Column(id: 1, name: "id", ty: "int64", primaryKey: true),
      embedding,
    ], indexes = indexes)
    check wire.contains("\"embedding_source\":{\"kind\":\"configured_model\"")
    for kind in ["bitmap", "fm_index", "ann", "learned_range", "minhash", "sparse"]:
      check wire.contains("\"kind\":\"" & kind & "\"")
    check wire.contains("\"quantization\":\"dense\"")
    check wire.contains("\"predicate\":\"embedding IS NOT NULL\"")

  test "history retention payload uses the exact frozen key":
    ## Test the client's actual code path, not just Nim's %*{} macro.
    let body = setHistoryRetentionPayload(42)
    check body.contains("\"history_retention_epochs\"")
    check body.contains("\"history_retention_epochs\":42")
    check not body.contains("earliest_retained_epoch")
