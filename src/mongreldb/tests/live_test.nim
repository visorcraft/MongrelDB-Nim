## Live integration tests for the mongreldb Nim client.
##
## Boots a real mongreldb-server daemon and exercises the client end to end.
## The daemon binary is resolved in this order:
##   1. MONGRELDB_SERVER env var (path to the server binary).
##   2. ./bin/mongreldb-server relative to the current working directory.
##   3. mongreldb-server on PATH.
##
## If no binary is available and MONGRELDB_URL is unset, every test self-skips.
## Set MONGRELDB_URL to point at an already-running daemon to skip the boot.

import std/[os, osproc, strutils, strformat, json, tables, times, monotimes, net]

import mongreldb

var gPassed = 0
var gFailed = 0

proc check(cond: bool; msg: string) =
  if cond:
    inc gPassed
  else:
    inc gFailed
    stderr.writeLine(&"FAIL: {msg}")

proc uniqueTable(prefix: string): string =
  let now = getMonoTime().ticks
  &"{prefix}_{now.toHex()}"

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  let local = s.getLocalAddr()
  s.close()
  return parseInt($local[1])

proc waitForHealth(db: MongrelDB; maxMs: int): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = maxMs)
  while getMonoTime() < deadline:
    if db.health():
      return true
    sleep(500)
  return false

proc resolveServerBinary(): string =
  let env = getEnv("MONGRELDB_SERVER", "")
  if env.len > 0 and fileExists(env):
    return env
  if fileExists("bin/mongreldb-server"):
    return "bin/mongreldb-server"
  let r = execCmdEx("sh -c 'command -v mongreldb-server'")
  if r.exitCode == 0 and r.output.strip().len > 0:
    return r.output.strip()
  return ""

proc startDaemon(): tuple[db: MongrelDB, ok: bool, pid: int, logPath: string] =
  let url = getEnv("MONGRELDB_URL", "")
  if url.len > 0:
    let db = newMongrelDB(url)
    if not db.health():
      stderr.writeLine(&"mongreldb: MONGRELDB_URL={url} is not reachable")
      return (db, false, 0, "")
    return (db, true, 0, "")

  let bin = resolveServerBinary()
  if bin.len == 0:
    echo "No mongreldb-server binary found; skipping live tests."
    return (MongrelDB(), false, 0, "")

  let port = freePort()
  let dataDir = &"/tmp/mongreldb-nim-test-{port}"
  if dirExists(dataDir):
    removeDir(dataDir)
  createDir(dataDir)

  # Boot the daemon detached, mirroring the Ruby/Go live harnesses. The daemon
  # is backgrounded through the shell with its stdout+stderr redirected to a log
  # file and its stdin from /dev/null; its pid is written to a pidfile (NOT the
  # shell's stdout) so the parent does not block on a pipe held open by the
  # backgrounded child. `execCmd` is used (rather than `execCmdEx`) precisely
  # because it captures no output - `execCmdEx`'s readLine loop would hang
  # forever on the inherited pipe write end kept open by the daemon.
  let logPath = dataDir & ".log"
  let pidPath = dataDir & ".pid"
  let inner = bin.quoteShell() & " " & dataDir.quoteShell() & " --port " & $port &
      " > " & logPath.quoteShell() & " 2>&1 < /dev/null & echo $! > " &
      pidPath.quoteShell()
  discard execCmd("sh -c " & inner.quoteShell())
  var pid = 0
  if fileExists(pidPath):
    try:
      pid = parseInt(readFile(pidPath).strip())
    except ValueError:
      pid = 0
  if pid == 0:
    stderr.writeLine("mongreldb: failed to start server (no pid)")
    return (MongrelDB(), false, 0, logPath)

  let db = newMongrelDB(&"http://127.0.0.1:{port}")
  if not waitForHealth(db, 30_000):
    stderr.writeLine("mongreldb: server did not become healthy")
    if fileExists(logPath):
      stderr.writeLine(readFile(logPath))
    return (db, false, pid, logPath)
  return (db, true, pid, logPath)

proc runTests(db: MongrelDB) =
  # health
  check(db.health(), "health")

  # createTable + count
  block:
    let name = uniqueTable("nim_tbl")
    discard db.createTable(name, [
      Column(id: 1, name: "id", ty: "int64", primaryKey: true, nullable: false),
      Column(id: 2, name: "amount", ty: "float64", primaryKey: false, nullable: false),
    ])
    check(db.count(name) == 0, "count empty == 0")

  # put + count round trip
  block:
    let name = uniqueTable("nim_put")
    discard db.createTable(name, [
      Column(id: 1, name: "id", ty: "int64", primaryKey: true, nullable: false),
      Column(id: 2, name: "amount", ty: "float64", primaryKey: false, nullable: false),
    ])
    discard db.put(name, {1'i64: %1'i64, 2'i64: %99.5})
    discard db.put(name, {1'i64: %2'i64, 2'i64: %150.0})
    check(db.count(name) == 2, "count == 2 after two puts")

  # query by pk
  block:
    let name = uniqueTable("nim_pk")
    discard db.createTable(name, [Column(id: 1, name: "id", ty: "int64",
        primaryKey: true, nullable: false)])
    discard db.put(name, {1'i64: %42'i64})
    discard db.put(name, {1'i64: %43'i64})

    let params = parseJson("""{"value": 42}""")
    var q = db.query(name).where("pk", params)
    let rows = q.execute()
    check(rows.len == 1, "pk query returns 1 row")

  # query range + truncated
  block:
    let name = uniqueTable("nim_range")
    discard db.createTable(name, [
      Column(id: 1, name: "id", ty: "int64", primaryKey: true, nullable: false),
      Column(id: 2, name: "amount", ty: "int64", primaryKey: false, nullable: false),
    ])
    discard db.put(name, {1'i64: %1'i64, 2'i64: %50'i64})
    discard db.put(name, {1'i64: %2'i64, 2'i64: %120'i64})
    discard db.put(name, {1'i64: %3'i64, 2'i64: %200'i64})

    let params = parseJson("""{"column": 2, "min": 100, "max": 150}""")
    var q = db.query(name).where("range", params).limit(100)
    let rows = q.execute()
    check(rows.len >= 1, "range query returns >= 1 row")
    check(not q.truncated, "range query not truncated")

  # transaction put + commit
  block:
    let name = uniqueTable("nim_txn")
    discard db.createTable(name, [Column(id: 1, name: "id", ty: "int64",
        primaryKey: true, nullable: false)])

    var txn = db.begin()
    discard txn.put(name, {1'i64: %1'i64})
    discard txn.put(name, {1'i64: %2'i64})
    discard txn.put(name, {1'i64: %3'i64})
    check(txn.count() == 3, "txn stages 3 ops")
    let results = txn.commit()
    check(results.len == 3, "txn commit returns 3 results")
    check(db.count(name) == 3, "txn count == 3")

  # deleteByPk
  block:
    let name = uniqueTable("nim_del")
    discard db.createTable(name, [Column(id: 1, name: "id", ty: "int64",
        primaryKey: true, nullable: false)])
    discard db.put(name, {1'i64: %5'i64})
    check(db.count(name) == 1, "deleteByPk: count == 1 before delete")
    db.deleteByPk(name, %5'i64)
    check(db.count(name) == 0, "deleteByPk: count == 0 after delete")

  # sql (SELECT 1 streams Arrow IPC rather than JSON; just assert it runs)
  block:
    discard db.sql("SELECT 1")
    check(true, "sql SELECT 1 runs")

  # schema + schemaFor
  block:
    let name = uniqueTable("nim_schema")
    discard db.createTable(name, [
      Column(id: 1, name: "id", ty: "int64", primaryKey: true, nullable: false),
      Column(id: 2, name: "amount", ty: "float64", primaryKey: false, nullable: false),
    ])

    let catalog = db.schema()
    check(catalog.contains(name), "schema catalog contains table")

    let desc = db.schemaFor(name)
    check(desc.kind == JObject, "schemaFor returns object")
    check(desc.hasKey("columns"), "schemaFor has columns")
    check(desc["columns"].len == 2, "schemaFor has 2 columns")

  # tableNames lists created table
  block:
    let name = uniqueTable("nim_tables")
    discard db.createTable(name, [Column(id: 1, name: "id", ty: "int64",
        primaryKey: true, nullable: false)])
    let names = db.tableNames()
    var found = false
    for n in names:
      if n == name:
        found = true
        break
    check(found, "tableNames lists created table")

  # error: schemaFor on a nonexistent table raises NotFoundError
  block:
    let name = uniqueTable("nim_missing")
    var threw = false
    try:
      discard db.schemaFor(name)
    except NotFoundError:
      threw = true
    except MongrelDBError:
      # Some daemon builds return a different non-2xx; accept any typed error.
      threw = true
    check(threw, "schemaFor on missing table raises")

proc main() =
  let (db, ok, pid, logPath) = startDaemon()
  defer:
    # Tear the daemon down when the runner exits, regardless of outcome.
    if pid != 0:
      try:
        discard execCmd("kill " & $pid)
      except OSError:
        discard
  if not ok:
    if getEnv("MONGRELDB_URL", "").len > 0:
      quit(1)
    return
  runTests(db)
  echo &"passed={gPassed} failed={gFailed}"
  if gFailed > 0:
    quit(1)

when isMainModule:
  main()
