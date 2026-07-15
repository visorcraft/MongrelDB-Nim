# Package manifest for the MongrelDB Nim client.
#
# A pure Nim HTTP client for MongrelDB — typed CRUD, a fluent query builder,
# idempotent batch transactions, SQL, and schema introspection. Built on the
# standard library (std/httpclient, std/json) with no external dependencies.

packageName     = "mongreldb"
version         = "0.55.0"
author          = "Visorcraft"
description     = "Pure Nim HTTP client for MongrelDB — typed CRUD, fluent query builder, idempotent batch transactions, SQL, and schema introspection."
license         = "MIT OR Apache-2.0"
srcDir          = "src"
installExt      = @["nim"]

requires "nim >= 2.0"

# Live integration suite: boots a real mongreldb-server daemon and exercises
# the client end to end. Resolve the binary via MONGRELDB_SERVER, ./bin/
# mongreldb-server, or PATH; set MONGRELDB_URL to point at a running daemon.
task liveTest, "Run the live integration suite against mongreldb-server":
  --path: "src"
  --mm: orc
  exec "nim c -d:mongreldbLiveTest --path:src --mm:orc -o:build/live_test src/mongreldb/tests/live_test.nim"
  exec "./build/live_test"
