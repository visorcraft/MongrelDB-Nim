## mongreldb is the pure Nim HTTP client for MongrelDB.
##
## It talks to a running mongreldb-server daemon's JSON API over the standard
## library `std/httpclient` client - no C ABI bindings to the engine, no
## external dependencies. The surface mirrors the MongrelDB PHP, Go, Java, and
## D clients: typed CRUD, a fluent query builder that pushes conditions down to
## the engine's native indexes, idempotent batch transactions, full SQL access,
## and schema introspection.
##
## Connect with a base URL:
##
## .. code-block:: nim
##
##    let db = newMongrelDB("http://127.0.0.1:8453")
##    if db.health():
##      echo "daemon is up"

import std/[base64, httpclient, json, options, strutils, tables, uri]

# NOTE: the submodule imports (mongreldb/transaction, mongreldb/query) are at
# the BOTTOM of this file. They import `mongreldb` for the MongrelDB type and
# helpers, so they must be parsed after those definitions exist - otherwise the
# circular dependency leaves `MongrelDB` undeclared in the submodules.

const
  defaultBaseURL* = "http://127.0.0.1:8453"
    ## The daemon address used when none is supplied.
  maxResponseBytes* = 268435456
    ## Caps the size of a response body read from the daemon (256 MB). Bodies
    ## larger than this raise a `QueryError`.

type
  MongrelDBError* = ref object of CatchableError
    ## Base type for every error raised by the MongrelDB client. Every non-2xx
    ## response is mapped to a typed subclass. Catch `MongrelDBError` to handle
    ## any failure, or catch one of the specific subclasses.
    status*: int          ## HTTP status code, or -1 when unknown.
    code*: string         ## Server's structured error code (e.g. UNIQUE_VIOLATION).
    opIndex*: int         ## Offending op index in a failed transaction, or -1.

  AuthError* = ref object of MongrelDBError
    ## Raised for HTTP 401 or 403 - bad or missing credentials.

  NotFoundError* = ref object of MongrelDBError
    ## Raised for HTTP 404 - a missing table, schema, or other resource.

  ConflictError* = ref object of MongrelDBError
    ## Raised for HTTP 409 - a unique, foreign-key, check, or trigger
    ## constraint violation.

  QueryError* = ref object of MongrelDBError
    ## Raised for HTTP 400 or 5xx, and for any other request-level failure not
    ## covered by the more specific subclasses. Also used for transport
    ## failures (status -1).

  Column* = object
    ## Describes one column in a CREATE TABLE request. Serialized verbatim;
    ## the recognized keys are `id`, `name`, `ty`, `primary_key`, `nullable`,
    ## and — when present — `enum_variants`, `default_value`, and
    ## `default_expr`, matching the daemon's table-create extractor. When
    ## multiple default fields are set, client-side precedence is
    ## `defaultExpr` → `defaultValueJson` → `defaultValue`.
    id*: int64
    name*: string
    ty*: string
    primaryKey*: bool
    nullable*: bool
    enumVariants*: seq[string]
      ## Enum variant names; emitted as `enum_variants` only when non-empty.
    defaultValue*: Option[string]
      ## Column default; emitted as `default_value` only when present.
    defaultValueJson*: Option[JsonNode]
      ## Static JSON scalar. Takes precedence over `defaultValue`.
    defaultExpr*: Option[string]
      ## Dynamic default: `now` or `uuid`. Takes precedence over all other
      ## default fields.

  MongrelDB* = object
    ## The MongrelDB HTTP client. Build one with `newMongrelDB` and use its
    ## methods for health, table management, CRUD, query, SQL, and schema.
    baseURL: string
    token: string
    username: string
    password: string
    timeoutMs: int

proc newMongrelDB*(url: string = defaultBaseURL; token: string = "";
    username: string = ""; password: string = ""): MongrelDB =
  ## Construct a client for the daemon at `url`.
  ##
  ## A non-empty `token` authenticates requests with a Bearer header
  ## (`--auth-token` mode) and takes precedence over basic-auth credentials.
  ## When `token` is empty, a non-empty `username` enables HTTP Basic auth
  ## (`--auth-users` mode); `password` may be empty.
  var base = if url.len == 0: defaultBaseURL else: url
  while base.len > 0 and base[^1] == '/':
    base.setLen(base.len - 1)
  result = MongrelDB(
    baseURL: base,
    token: token,
    username: username,
    password: password,
    timeoutMs: 30_000,
  )

proc baseURL*(db: MongrelDB): string {.inline.} = db.baseURL
  ## The daemon base URL this client was configured with (no trailing slash).

proc setTimeout*(db: var MongrelDB; ms: int): var MongrelDB {.inline, discardable.} =
  ## Set the per-request timeout (milliseconds). Defaults to 30000.
  db.timeoutMs = ms
  result = db

# ── Helpers (defined before the public methods that use them) ────────────────

proc newQueryError(msg: string; status: int = -1; code: string = ""): QueryError =
  result = QueryError(msg: msg, status: status, code: code, opIndex: -1)

# jsonToLong coerces a JSON number/integer/string to an int64, returning 0 on
# failure.
proc jsonToLong(v: JsonNode): int64 =
  case v.kind
  of JInt: v.getInt()
  of JFloat: int64(v.getFloat())
  of JString:
    try: parseInt(v.str).int64
    except ValueError: 0'i64
  of JBool: (if v.getBool(): 1'i64 else: 0'i64)
  else: 0'i64

# jsonToString renders a JSON scalar to its display string for error messages.
proc jsonToString(v: JsonNode): string =
  case v.kind
  of JString: v.str
  of JInt: $v.getInt()
  of JFloat: $v.getFloat()
  of JBool: $v.getBool()
  of JNull: "null"
  else: $v

# methodToEnum maps an uppercase method name to std.httpclient.HttpMethod.
proc methodToEnum(verb: string): HttpMethod =
  case verb.toUpperAscii()
  of "GET": HttpGet
  of "HEAD": HttpHead
  of "POST": HttpPost
  of "PUT": HttpPut
  of "DELETE": HttpDelete
  else: HttpGet

# Maps an HTTP status code and response body to a typed exception. It
# best-effort decodes the server's JSON error envelope
# ({error:{message,code,op_index}}) and falls back to the raw body.
proc toException(status: int; body: string): MongrelDBError =
  var message = ""
  var code = ""
  var opIndex = -1

  let trimmed = body.strip()
  if trimmed.len > 0 and trimmed[0] == '{':
    try:
      let parsed = parseJson(body)
      if parsed.kind == JObject:
        # Prefer the nested {"error": {...}} envelope.
        if parsed.hasKey("error") and parsed["error"].kind == JObject:
          let err = parsed["error"]
          if err.hasKey("message"):
            message = jsonToString(err["message"])
          if err.hasKey("code"):
            code = jsonToString(err["code"])
          if err.hasKey("op_index"):
            opIndex = int(jsonToLong(err["op_index"]))
        # Fall back to a flat {"message": ..., "code": ...} object.
        if message.len == 0 and code.len == 0 and opIndex == -1:
          if parsed.hasKey("message"):
            message = jsonToString(parsed["message"])
          if parsed.hasKey("code"):
            code = jsonToString(parsed["code"])
    except JsonParsingError:
      discard
  if message.len == 0 and body.len > 0:
    message = body
  if message.len == 0:
    case status
    of 401, 403: message = "authentication failed (" & $status & ")"
    of 404: message = "resource not found"
    of 409: message = "constraint violation"
    else: message = "server error (" & $status & ")"

  case status
  of 401, 403:
    return AuthError(msg: message, status: status, code: code, opIndex: opIndex)
  of 404:
    return NotFoundError(msg: message, status: status, code: code, opIndex: opIndex)
  of 409:
    return ConflictError(msg: message, status: status, code: code, opIndex: opIndex)
  else:
    return QueryError(msg: message, status: status, code: code, opIndex: opIndex)

# rejectCrlf guards against CRLF injection into HTTP headers by raising a
# QueryError when a value contains a carriage return or line feed. Without it,
# a token or password containing "\r\n" could smuggle extra header lines.
proc rejectCrlf(value, field: string) =
  if '\r' in value or '\n' in value:
    raise newQueryError("mongreldb: illegal CR/LF in " & field & " value")

# applyAuth sets the Authorization header according to the configured
# credentials. A bearer token takes precedence over basic auth.
proc applyAuth(db: MongrelDB; client: HttpClient) =
  if db.token.len > 0:
    rejectCrlf(db.token, "token")
    client.headers["Authorization"] = "Bearer " & db.token
  elif db.username.len > 0:
    rejectCrlf(db.username, "username")
    rejectCrlf(db.password, "password")
    let creds = db.username & ":" & db.password
    client.headers["Authorization"] = "Basic " & base64.encode(creds)

# decodeResults pulls the results array out of a /kit/txn response.
proc decodeResults(v: JsonNode): seq[JsonNode] =
  if v.kind != JObject or not v.hasKey("results"):
    return @[]
  let r = v["results"]
  if r.kind != JArray: return @[]
  result = newSeqOfCap[JsonNode](r.len)
  for row in r: result.add(row)

# firstResult returns the first element of results, or an empty object.
proc firstResult(results: seq[JsonNode]): JsonNode =
  if results.len == 0: newJObject() else: results[0]

# ── HTTP plumbing ────────────────────────────────────────────────────────────

proc request*(db: MongrelDB; verb, path: string; body: string): string =
  ## Build and run one request. The server's JSON extractors require an
  ## explicit `Content-Type` header on any request carrying a JSON body, so
  ## one is added whenever `body` is non-empty. Non-2xx responses are mapped
  ## to typed exceptions via `toException`.
  let url = db.baseURL & "/" & path.strip(chars = {'/'}, leading = true)
  let m = methodToEnum(verb)
  # maxRedirects = 0 prevents the client from following redirects, which
  # would otherwise leak the Authorization header to whatever host the
  # redirect points at.
  var client = newHttpClient(timeout = db.timeoutMs, maxRedirects = 0)
  defer: client.close()
  client.headers = newHttpHeaders({"Accept": "application/json"})
  if body.len > 0:
    client.headers["Content-Type"] = "application/json"
  applyAuth(db, client)

  let resp =
    try:
      client.request(url, httpMethod = m, body = body)
    except Exception as e:
      raise newQueryError("mongreldb: request " & verb & " " & path &
          " failed: " & e.msg, -1)

  let status = resp.code.int
  let data = resp.body
  # Cap the response: a body larger than maxResponseBytes is aborted as a
  # QueryError rather than returning unbounded data.
  if data.len > maxResponseBytes:
    raise newQueryError("mongreldb: response body exceeds " & $maxResponseBytes &
        " bytes", status)
  if status < 200 or status >= 300:
    raise toException(status, data)
  return data

proc getRaw*(db: MongrelDB; path: string): string =
  ## GET `path` and return the raw response body.
  result = db.request("GET", path, "")

proc postRaw*(db: MongrelDB; path: string; payload: JsonNode): string =
  ## POST `payload` (as JSON) to `path` and return the raw response body.
  let encoded = pretty(payload)
  result = db.request("POST", path, encoded)

proc getJson*(db: MongrelDB; path: string): JsonNode =
  ## GET `path` and decode the JSON body (empty body → `null` node).
  let body = db.getRaw(path)
  if body.len == 0: return newJNull()
  try:
    result = parseJson(body)
  except JsonParsingError as e:
    raise newQueryError("mongreldb: decode response: " & e.msg)

proc postJson*(db: MongrelDB; path: string; payload: JsonNode): JsonNode =
  ## POST `payload` (as JSON) to `path` and decode the JSON response.
  let body = db.postRaw(path, payload)
  if body.len == 0: return newJNull()
  try:
    result = parseJson(body)
  except JsonParsingError as e:
    raise newQueryError("mongreldb: decode response: " & e.msg)

# ── Cells & txn helpers ──────────────────────────────────────────────────────

proc flattenCells*(cells: openArray[(int64, JsonNode)]): JsonNode =
  ## Flatten a sequence of `(column_id, value)` pairs to the server's flat
  ## `[col_id, value, col_id, value, ...]` array. Pair order is not
  ## significant.
  result = newJArray()
  for (id, val) in cells:
    result.add(%id)
    result.add(val)

proc commitTxn*(db: MongrelDB; ops: seq[JsonNode]; idempotencyKey: string): seq[JsonNode] =
  ## Send a batch of staged operations atomically to `/kit/txn` and return the
  ## per-operation results array. Exposed for the `Transaction` type.
  var payload = newJObject()
  payload["ops"] = %ops
  if idempotencyKey.len > 0:
    payload["idempotency_key"] = %idempotencyKey
  let resp = db.postJson("/kit/txn", payload)
  result = decodeResults(resp)

proc urlPathEscape*(seg: string): string =
  ## Percent-encode a path segment so table names containing '/', '?', '#',
  ## or spaces cannot inject extra segments or break routing. Only RFC 3986
  ## unreserved characters pass through unescaped.
  const hex = "0123456789ABCDEF"
  var needEscape = false
  for b in seg:
    if b notin {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'}:
      needEscape = true
      break
  if not needEscape:
    return seg
  result = newStringOfCap(seg.len * 3)
  for b in seg:
    if b in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'}:
      result.add(b)
    else:
      let bb = byte(b)
      result.add('%')
      result.add(hex[int(bb shr 4) and 0x0f])
      result.add(hex[int(bb) and 0x0f])

# ── Health & tables ──────────────────────────────────────────────────────────

proc health*(db: MongrelDB): bool =
  ## Report whether the daemon is reachable and healthy. A transport failure
  ## or non-2xx response yields `false` rather than raising.
  try:
    discard db.getRaw("/health")
    true
  except MongrelDBError:
    false

proc tableNames*(db: MongrelDB): seq[string] =
  ## List all table names in the database. The endpoint returns a bare JSON
  ## array of strings.
  let v = db.getJson("/tables")
  if v.kind != JArray: return @[]
  result = newSeqOfCap[string](v.len)
  for entry in v:
    result.add(if entry.kind == JString: entry.str else: $entry)

proc historyRetention*(db: MongrelDB): tuple[historyRetentionEpochs, earliestRetainedEpoch: int64] =
  let v = db.getJson("/history/retention")
  if v.kind != JObject or not v.hasKey("history_retention_epochs") or not v.hasKey("earliest_retained_epoch"):
    raise newQueryError("mongreldb: malformed history retention response")
  (jsonToLong(v["history_retention_epochs"]), jsonToLong(v["earliest_retained_epoch"]))

## `setHistoryRetentionPayload` builds the JSON body for PUT /history/retention.
## Exposed so wire-shape tests can assert the exact key without a daemon.
proc setHistoryRetentionPayload*(epochs: int64): string =
  $(%*{"history_retention_epochs": epochs})

proc setHistoryRetentionEpochs*(db: MongrelDB; epochs: int64): tuple[historyRetentionEpochs, earliestRetainedEpoch: int64] =
  let v = parseJson(db.request("PUT", "/history/retention", setHistoryRetentionPayload(epochs)))
  if v.kind != JObject or not v.hasKey("history_retention_epochs") or not v.hasKey("earliest_retained_epoch"):
    raise newQueryError("mongreldb: malformed history retention response")
  (jsonToLong(v["history_retention_epochs"]), jsonToLong(v["earliest_retained_epoch"]))

proc historyRetentionEpochs*(db: MongrelDB): int64 = db.historyRetention().historyRetentionEpochs
proc earliestRetainedEpoch*(db: MongrelDB): int64 = db.historyRetention().earliestRetainedEpoch

proc columnToJsonNode*(c: Column): JsonNode =
  ## Serialize a single `Column` to its request JSON shape. `enum_variants`
  ## is included only when `enumVariants` is non-empty, and `default_value`
  ## only when `defaultValue` is present.
  result = newJObject()
  result["id"] = %c.id
  result["name"] = %c.name
  result["ty"] = %c.ty
  result["primary_key"] = %c.primaryKey
  result["nullable"] = %c.nullable
  if c.enumVariants.len > 0:
    result["enum_variants"] = %c.enumVariants
  if c.defaultExpr.isSome:
    result["default_expr"] = %c.defaultExpr.get()
  elif c.defaultValueJson.isSome:
    result["default_value"] = c.defaultValueJson.get()
  elif c.defaultValue.isSome:
    result["default_value"] = %c.defaultValue.get()

proc createTablePayload*(name: string; columns: openArray[Column];
    constraints: JsonNode = nil): JsonNode =
  ## Build the exact JSON object sent to `POST /kit/create_table`.
  var colArr = newJArray()
  for c in columns:
    colArr.add(columnToJsonNode(c))
  result = newJObject()
  result["name"] = %name
  result["columns"] = colArr
  if not constraints.isNil:
    result["constraints"] = constraints

proc createTable*(db: MongrelDB; name: string; columns: openArray[Column];
    constraints: JsonNode = nil): int64 =
  ## Create a table named `name` with the given columns and return the
  ## assigned table id.
  let payload = createTablePayload(name, columns, constraints)
  let resp = db.postJson("/kit/create_table", payload)
  if resp.kind == JObject and resp.hasKey("table_id") and
      resp["table_id"].kind == JInt:
    return resp["table_id"].getInt()
  return 0'i64

proc dropTable*(db: MongrelDB; name: string) =
  ## Drop a table by name.
  discard db.request("DELETE", "/tables/" & urlPathEscape(name), "")

proc count*(db: MongrelDB; table: string): int64 =
  ## Return the row count for a table.
  let v = db.getJson("/tables/" & urlPathEscape(table) & "/count")
  if v.kind == JObject and v.hasKey("count"):
    return jsonToLong(v["count"])
  return 0'i64

# ── CRUD (via the Kit typed transaction endpoint) ────────────────────────────

proc put*(db: MongrelDB; table: string; cells: openArray[(int64, JsonNode)];
    idempotencyKey: string = ""): JsonNode =
  ## Insert a row. `idempotencyKey`, when non-empty, makes the commit safe to
  ## retry - the daemon returns the original result on duplicate commits.
  ##
  ## `cells` is a sequence of `(column_id, value)` pairs; the client flattens
  ## them to the server's `[col_id, value, col_id, value, ...]` array before
  ## sending. Pair order is not significant.
  ##
  ## Returns the per-operation result object (the first element of the
  ## server's results array), or an empty object if none.
  var op = newJObject()
  var putOp = newJObject()
  putOp["table"] = %table
  putOp["cells"] = flattenCells(cells)
  op["put"] = putOp
  let results = db.commitTxn(@[op], idempotencyKey)
  return firstResult(results)

proc upsert*(db: MongrelDB; table: string; cells: openArray[(int64, JsonNode)];
    updateCells: openArray[(int64, JsonNode)] = @[];
    idempotencyKey: string = ""): JsonNode =
  ## Upsert (insert or update on PK conflict) a row. `cells` are the insert
  ## values as `(column_id, value)` pairs; `updateCells`, when non-empty, are
  ## the values to apply on a primary-key conflict (an empty seq means DO
  ## NOTHING). `idempotencyKey`, when non-empty, makes the commit safe to retry.
  ##
  ## Returns the per-operation result object (the first element of the
  ## server's results array), or an empty object if none.
  var op = newJObject()
  var upsertOp = newJObject()
  upsertOp["table"] = %table
  upsertOp["cells"] = flattenCells(cells)
  if updateCells.len > 0:
    upsertOp["update_cells"] = flattenCells(updateCells)
  op["upsert"] = upsertOp
  let results = db.commitTxn(@[op], idempotencyKey)
  return firstResult(results)

proc deleteByPk*(db: MongrelDB; table: string; pk: JsonNode) =
  ## Remove a row by its primary-key value.
  var op = newJObject()
  var del = newJObject()
  del["table"] = %table
  del["pk"] = pk
  op["delete_by_pk"] = del
  discard db.commitTxn(@[op], "")

# ── Query & Transactions ─────────────────────────────────────────────────────
# `query()` and `begin()` are defined after the submodule imports below, since
# they return `QueryBuilder` / `Transaction` which those modules define.

# ── SQL ──────────────────────────────────────────────────────────────────────

proc sql*(db: MongrelDB; sqlText: string): seq[JsonNode] =
  ## Execute a SQL statement via the `/sql` endpoint, requesting JSON output.
  ## The server returns a JSON array of row objects keyed by column name, e.g.
  ## `[{"id": 1, "name": "Alice", "score": 95.5}]`. For statements that yield
  ## no rows (DDL/DML), the body is empty and an empty seq is returned.
  var payload = newJObject()
  payload["sql"] = %sqlText
  payload["format"] = %"json"
  let body = db.postRaw("/sql", payload)
  let trimmed = body.strip()
  if trimmed.len == 0:
    return @[]
  # JSON format requested; a leading '{' is a single object (e.g. an error
  # envelope), not a row set, so return an empty seq. A '[' begins the row
  # array to decode.
  if trimmed[0] != '[':
    return @[]
  try:
    let parsed = parseJson(body)
    if parsed.kind == JArray:
      result = newSeqOfCap[JsonNode](parsed.len)
      for row in parsed:
        result.add(row)
    else:
      result = @[]
  except JsonParsingError:
    return @[]

# ── Schema ───────────────────────────────────────────────────────────────────

proc schema*(db: MongrelDB): OrderedTable[string, JsonNode] =
  ## Return the full schema catalog: a table-name-to-descriptor map.
  let v = db.getJson("/kit/schema")
  result = initOrderedTable[string, JsonNode]()
  if v.kind == JObject and v.hasKey("tables") and v["tables"].kind == JObject:
    for k, desc in v["tables"]:
      result[k] = desc

proc schemaFor*(db: MongrelDB; table: string): JsonNode =
  ## Return the descriptor for a single table.
  let v = db.getJson("/kit/schema/" & urlPathEscape(table))
  if v.kind == JObject: v else: newJObject()

# ── Submodules ───────────────────────────────────────────────────────────────
# Imported last so the `MongrelDB` type and helpers above are visible to them.
# Both transaction.nim and query.nim `import mongreldb`.
import mongreldb/[transaction, query]
export transaction, query

# ── Query & Transactions (return submodule types) ───────────────────────────
# Defined after the submodule imports so `QueryBuilder` and `Transaction` are
# in scope.

proc query*(db: MongrelDB; table: string): QueryBuilder =
  ## Start a fluent `QueryBuilder` against `table`.
  result = initQueryBuilder(db, table)

proc begin*(db: MongrelDB): Transaction =
  ## Start a new batch transaction. Operations staged on the returned
  ## `Transaction` are committed atomically in a single `/kit/txn` request.
  result = initTransaction(db)
