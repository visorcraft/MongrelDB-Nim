# Native Query Builder

`db.query(table)` returns a `QueryBuilder` that targets the daemon's
`/kit/query` endpoint. Conditions push down to the engine's specialized native
indexes for sub-millisecond lookups - the daemon never scans the whole table
to answer them.

This guide lists every condition type, the alias translation rules, projection,
and the truncated flag.

```nim
import std/json
import mongreldb
```

---

## The shape of a query

A query is a table name plus zero or more AND-ed conditions, an optional
column projection, and an optional row limit:

```nim
let q = db.query("orders")
    .where("range", parseJson("""{"column": 3, "min": 100.0, "max": 150.0}"""))
    .projection([1'i64, 2'i64])
    .limit(100)
let rows = q.execute()
```

- `where(type, params)` appends a condition. `params` is a `JsonNode` object.
- `projection(columnIDs)` restricts which columns come back.
- `limit(n)` caps the row count.
- `execute()` POSTs to `/kit/query` and returns the `rows` seq.

## Friendly aliases

The builder accepts readable aliases and translates them to the daemon's exact
on-wire keys before sending. Both spellings are accepted, so use whichever is
clearer.

| friendly alias   | on-wire key    |
|------------------|----------------|
| `column`         | `column_id`    |
| `min`            | `lo`           |
| `max`            | `hi`           |
| `min_inclusive`  | `lo_inclusive` |
| `max_inclusive`  | `hi_inclusive` |

For the `fm_contains` and `fm_contains_all` conditions only, `value` is
aliased to `pattern`. For every other condition (e.g. `pk`, `bitmap_eq`),
`value` is the canonical key and passes through unchanged.

```nim
# These two are identical on the wire:
.where("range", parseJson("""{"column": 3, "min": 100.0}"""))
.where("range", parseJson("""{"column_id": 3, "lo": 100.0}"""))
```

## Condition types

### `pk` - exact primary-key match

Returns the single row whose primary key equals `value`:

```nim
discard db.query("orders")
    .where("pk", parseJson("""{"value": 2}"""))
    .execute()
```

### `bitmap_eq` - equality on a bitmap-indexed column

For low-cardinality columns (categories, booleans, enums):

```nim
discard db.query("orders")
    .where("bitmap_eq", parseJson("""{"column": 2, "value": "Alice"}"""))
    .execute()
```

### `bitmap_in` - IN predicate on a bitmap-indexed column

Returns rows where the column equals any of the listed values:

```nim
discard db.query("orders")
    .where("bitmap_in", parseJson("""{"column": 2, "value": ["Alice", "Bob"]}"""))
    .execute()
```

### `range` - integer range predicate

Closed or half-open integer ranges. `min`/`max` are inclusive by default;
override with `min_inclusive`/`max_inclusive`:

```nim
discard db.query("orders")
    .where("range", parseJson("""{"column": 1, "min": 10, "max": 100}"""))
    .execute()

# exclusive upper bound
discard db.query("orders")
    .where("range", parseJson("""{
        "column": 1, "min": 10, "max": 100, "max_inclusive": false
    }"""))
    .execute()
```

### `range_f64` - float range predicate

Same shape as `range`, for `float64` columns:

```nim
discard db.query("orders")
    .where("range_f64", parseJson("""{"column": 3, "min": 50.0, "max": 150.0}"""))
    .execute()
```

### `is_null` / `is_not_null` - null checks

```nim
discard db.query("orders")
    .where("is_null", parseJson("""{"column": 2}"""))
    .execute()

discard db.query("orders")
    .where("is_not_null", parseJson("""{"column": 2}"""))
    .execute()
```

### `fm_contains` - full-text substring search (FM-index)

Substring search backed by a FM-index. `value` is aliased to `pattern`:

```nim
discard db.query("documents")
    .where("fm_contains", parseJson("""{"column": 2, "value": "database performance"}"""))
    .limit(10)
    .execute()
```

### `fm_contains_all` - multiple substring patterns

All patterns must match:

```nim
discard db.query("documents")
    .where("fm_contains_all", parseJson("""{
        "column": 2,
        "value": ["database", "performance"]
    }"""))
    .limit(10)
    .execute()
```

### `ann` - dense vector similarity (HNSW)

Approximate nearest-neighbor search over a dense vector index (HNSW). Pass the
query vector and the number of neighbors to return:

```nim
discard db.query("embeddings")
    .where("ann", parseJson("""{
        "column": 5,
        "value": [0.12, 0.43, 0.99],
        "limit": 10
    }"""))
    .execute()
```

### `sparse_match` - sparse vector match

Match against a sparse vector index (e.g. BM25-style sparse retrieval):

```nim
discard db.query("docs")
    .where("sparse_match", parseJson("""{
        "column": 4,
        "value": {"indices": [10, 42, 99], "values": [0.5, 1.2, 0.8]}
    }"""))
    .limit(10)
    .execute()
```

### `min_hash_similar` - MinHash similarity

Jaccard-style similarity over MinHash signatures:

```nim
discard db.query("sets")
    .where("min_hash_similar", parseJson("""{
        "column": 3,
        "value": [1, 7, 9, 42],
        "limit": 10
    }"""))
    .execute()
```

## Projection

`projection(columnIDs)` returns only the listed columns, cutting bandwidth:

```nim
discard db.query("orders")
    .projection([1'i64, 2'i64])
    .execute()
```

Column ids are the stable on-wire identifiers from `createTable`, never the
names. Leave projection unset to receive all columns.

## Limit and truncation

`limit(n)` caps the number of rows. When the server caps the result, it sets
`truncated: true` in the response; the builder records this and exposes it
through the `truncated` accessor:

```nim
let q = db.query("orders")
    .where("range", parseJson("""{"column": 3, "min": 0}"""))
    .limit(100)
let rows = q.execute()
if q.truncated():
  # More than 100 rows matched - raise the limit or paginate.
  discard
```

`truncated` reflects the most recent `execute()` call. Build a new query, or
re-run `execute()`, before relying on it.

## Combining conditions

Conditions are AND-ed together. Chain as many as you need:

```nim
discard db.query("orders")
    .where("bitmap_in", parseJson("""{"column": 2, "value": ["Alice", "Bob"]}"""))
    .where("range", parseJson("""{"column": 3, "min": 50.0, "max": 150.0}"""))
    .projection([1'i64, 3'i64])
    .limit(50)
    .execute()
```

There is no client-side OR combinator. For OR across columns, use SQL (see
[sql.md](sql.md)).

## Inspecting the payload

`build()` returns the JSON object that will be POSTed, useful for logging or
testing:

```nim
let q = db.query("orders")
    .where("range", parseJson("""{"column": 3, "min": 100.0}"""))
    .limit(10)
let payload = q.build()
echo pretty(payload)
# {"table":"orders","conditions":[{"range":{"column_id":3,"lo":100.0}}],"limit":10}
```

Note the alias translation happened before serialization: `column` →
`column_id`, `min` → `lo`.

## Common pitfalls

**Using the column name instead of the id.** Pass the integer column id from
`createTable`, not the human-readable name. The `column` alias maps to
`column_id`; it does not look up names.

**Forgetting the alias is type-specific for `value`.** `value` → `pattern`
only for `fm_contains` and `fm_contains_all`. For `pk` and `bitmap_eq`,
`value` is canonical and must not be renamed.

**Expecting OR.** The builder ANDs conditions. Cross-column OR is a SQL
feature.

**Ignoring `truncated`.** If you page by incrementing a limit and never check
`truncated`, you may silently receive a capped result and treat it as
complete.

## Next steps

- [sql.md](sql.md) - when the typed builder is not enough
- [transactions.md](transactions.md) - atomic writes
- [errors.md](errors.md) - `QueryError` and friends
