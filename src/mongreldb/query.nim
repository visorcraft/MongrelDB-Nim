## mongreldb.query - fluent query builder for the /kit/query endpoint.
##
## A QueryBuilder builds a request for the daemon's /kit/query endpoint, where
## conditions push down to the engine's specialized indexes for sub-millisecond
## lookups.
##
## Condition parameters accept friendly aliases that are translated to the
## server's exact on-wire keys before sending (see where()):
##
##   - column         -> column_id
##   - min / max      -> lo / hi
##   - min_inclusive  -> lo_inclusive
##   - max_inclusive  -> hi_inclusive
##
## The server's canonical keys are accepted directly too.

import std/json
import mongreldb

# Translates friendly parameter aliases to the server's canonical on-wire
# keys. Both spellings are accepted, so callers may use whichever is clearer.
#
# Defined before the QueryBuilder methods that use it, because Nim does not
# support forward references to procs defined later in the same module.
proc normalizeCondition*(condType: string; params: JsonNode): JsonNode =
  result = newJObject()
  if params.kind != JObject:
    return params
  for key, val in params:
    let canonical =
      case key
      of "column": "column_id"
      of "min": "lo"
      of "max": "hi"
      of "min_inclusive": "lo_inclusive"
      of "max_inclusive": "hi_inclusive"
      of "value":
        # The docs historically used "value" for the FTS pattern; the server's
        # fm_contains key is "pattern". Only apply this for FTS conditions,
        # since pk/bitmap_eq use "value" canonically.
        if condType == "fm_contains" or condType == "fm_contains_all":
          "pattern"
        else:
          "value"
      else: key
    result[canonical] = val

type
  QueryBuilder* = ref object
    ## Builds a request for the daemon's `/kit/query` endpoint.
    ##
    ## Conditions are AND-ed together and pushed down to the engine's
    ## specialized indexes. The builder returns itself from each method so
    ## queries can be chained.
    ##
    ## `QueryBuilder` is a reference type so chained calls like
    ## `db.query(t).where(...).limit(...).execute()` mutate the same builder
    ## without requiring the caller to bind it to an lvalue first.
    client: MongrelDB
    table: string
    conditions: seq[JsonNode]
    projection: seq[int64]
    hasProjection: bool
    hasLimit: bool
    limitVal: int64
    hasOffset: bool
    offsetVal: int64
    lastTruncated: bool

proc initQueryBuilder*(client: MongrelDB; table: string): QueryBuilder =
  ## Construct a builder bound to `client` for `table`. Use
  ## `MongrelDB.query()` instead of constructing one directly.
  QueryBuilder(client: client, table: table, conditions: @[],
      projection: @[], hasProjection: false, hasLimit: false, limitVal: 0,
      hasOffset: false, offsetVal: 0,
      lastTruncated: false)

proc where*(q: QueryBuilder; condType: string; params: JsonNode): QueryBuilder =
  ## Add a native condition (AND-ed with any prior conditions).
  ##
  ## Available condition types include: `pk` (exact primary-key match,
  ## `{"value": pk}`), `bitmap_eq`, `bitmap_in`, `range`, `range_f64`,
  ## `is_null`, `is_not_null`, `fm_contains`, `fm_contains_all`, `ann`,
  ## `sparse_match`, `min_hash_similar`. `params` is a JSON object whose keys
  ## are the condition's parameters (friendly aliases accepted).
  var entry = newJObject()
  entry[condType] = normalizeCondition(condType, params)
  q.conditions.add(entry)
  result = q

proc projection*(q: QueryBuilder; columnIDs: openArray[int64]): QueryBuilder =
  ## Set the column ids to return. Leave unset for all columns.
  q.projection = @columnIDs
  q.hasProjection = columnIDs.len > 0
  result = q

proc limit*(q: QueryBuilder; n: int64): QueryBuilder =
  ## Cap the number of rows returned.
  q.hasLimit = true
  q.limitVal = n
  result = q

proc offset*(q: QueryBuilder; n: int64): QueryBuilder =
  ## Skip matching rows before applying the limit.
  q.hasOffset = true
  q.offsetVal = n
  result = q

proc build*(q: QueryBuilder): JsonNode =
  ## Build the request payload that will be sent to `/kit/query`.
  result = newJObject()
  result["table"] = %q.table
  if q.conditions.len > 0:
    result["conditions"] = %q.conditions
  if q.hasProjection and q.projection.len > 0:
    var cols = newJArray()
    for c in q.projection:
      cols.add(%c)
    result["projection"] = cols
  if q.hasLimit:
    result["limit"] = %q.limitVal
  if q.hasOffset:
    result["offset"] = %q.offsetVal

proc execute*(q: QueryBuilder): seq[JsonNode] =
  ## Run the query and return the matching rows. Also records whether the
  ## result was truncated by `limit()`; check it with `truncated`.
  let resp = q.client.postJson("/kit/query", q.build())
  result = @[]
  q.lastTruncated = false
  if resp.kind == JObject:
    if resp.hasKey("rows") and resp["rows"].kind == JArray:
      result = newSeqOfCap[JsonNode](resp["rows"].len)
      for row in resp["rows"]:
        result.add(row)
    if resp.hasKey("truncated") and resp["truncated"].kind == JBool:
      q.lastTruncated = resp["truncated"].getBool()

proc truncated*(q: QueryBuilder): bool {.inline.} =
  ## Whether the most recent `execute()` result was capped by the query limit.
  ## Returns `false` until `execute()` has been called.
  q.lastTruncated
