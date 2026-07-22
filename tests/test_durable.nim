# Offline unit tests for 0.64 durable HLC recovery parsers.
import std/[json, options, unittest]
import mongreldb

suite "durable HLC parse":
  test "query status parses structural HLC":
    let fixture = parseJson("""{
      "query_id": "abcdefabcdefabcdefabcdefabcdefab",
      "status": "committed",
      "state": "completed",
      "server_state": "completed",
      "terminal_state": "committed",
      "committed": true,
      "last_commit_epoch": 17,
      "last_commit_hlc": {
        "physical_micros": 1700000000000000,
        "logical": 3,
        "node_tiebreaker": 7
      },
      "outcome": {
        "committed": true,
        "last_commit_epoch": 17,
        "last_commit_hlc": {
          "physical_micros": 1700000000000000,
          "logical": 3,
          "node_tiebreaker": 7
        },
        "serialization": "succeeded",
        "serialization_state": "succeeded",
        "terminal_state": "committed"
      },
      "durable": {
        "committed": true,
        "last_commit_epoch": 17,
        "last_commit_hlc": {
          "physical_micros": 1700000000000000,
          "logical": 3,
          "node_tiebreaker": 7
        },
        "serialization": "succeeded",
        "serialization_state": "succeeded",
        "terminal_state": "committed"
      }
    }""")
    let status = parseQueryStatus(fixture)
    check status.committed.isSome
    check status.committed.get == true
    let hlc = commitHlc(status)
    check hlc.isSome
    check hlc.get.physicalMicros == 1700000000000000'u64
    check hlc.get.logical == 3'u32
    check hlc.get.nodeTiebreaker == 7'u32
    check serializationState(status) == "succeeded"
    check status.outcome.lastCommitEpoch.isSome
    check status.outcome.lastCommitEpoch.get == 17

  test "parseCommitHlc rejects missing physical_micros":
    check parseCommitHlc(nil).isNone
    check parseCommitHlc(newJObject()).isNone
    check parseCommitHlc(%*{"logical": 1}).isNone

  test "buildRetrieveTextRequest wire shape":
    let payload = buildRetrieveTextRequest("docs", 3, "cat sat", k = 5)
    check payload["table"].getStr == "docs"
    check payload["embedding_column"].getInt == 3
    check payload["text"].getStr == "cat sat"
    check payload["k"].getInt == 5
