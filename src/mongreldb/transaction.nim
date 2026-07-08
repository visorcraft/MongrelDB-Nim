## mongreldb.transaction — staging buffer for atomic batch commits.
##
## A Transaction stages operations locally and commits them atomically in a
## single /kit/txn request. The engine enforces unique, foreign-key, check, and
## trigger constraints at commit time; on any violation all operations roll
## back and commit raises a ConflictError carrying the server's structured
## error code and offending op index.
##
## A Transaction is single-use: after commit() or rollback() it must not be
## reused. Calling commit() or rollback() a second time raises ValueError.

import std/json
import mongreldb

const alreadyCommittedMsg* = "mongreldb: transaction already committed"
  ## Raised when commit() or rollback() is called on a transaction that has
  ## already been committed or rolled back.

type
  Transaction* = ref object
    ## Stages operations locally and commits them atomically.
    ##
    ## `Transaction` is a reference type so chained calls like
    ## `db.begin().put(...).put(...).commit()` mutate the same transaction
    ## without requiring the caller to bind it to an lvalue first.
    client: MongrelDB
    ops: seq[JsonNode]
    committed: bool

proc initTransaction*(client: MongrelDB): Transaction =
  ## Construct a transaction bound to `client`. Use `MongrelDB.begin()` instead
  ## of constructing one directly.
  Transaction(client: client, ops: @[], committed: false)

proc put*(t: Transaction; table: string;
    cells: openArray[(int64, JsonNode)]; returning = false): Transaction =
  ## Stage an insert. `returning`, when `true`, asks the daemon to echo the row
  ## in the per-operation result. Returns `t` for chaining.
  var op = newJObject()
  var putOp = newJObject()
  putOp["table"] = %table
  putOp["cells"] = flattenCells(cells)
  putOp["returning"] = %returning
  op["put"] = putOp
  t.ops.add(op)
  result = t

proc delete*(t: Transaction; table: string; rowId: int64): Transaction =
  ## Stage a delete by the internal row id. Returns `t` for chaining.
  var op = newJObject()
  var del = newJObject()
  del["table"] = %table
  del["row_id"] = %rowId
  op["delete"] = del
  t.ops.add(op)
  result = t

proc deleteByPk*(t: Transaction; table: string; pk: JsonNode): Transaction =
  ## Stage a delete by primary-key value. Returns `t` for chaining.
  var op = newJObject()
  var del = newJObject()
  del["table"] = %table
  del["pk"] = pk
  op["delete_by_pk"] = del
  t.ops.add(op)
  result = t

proc count*(t: Transaction): int {.inline.} =
  ## The number of staged operations.
  t.ops.len

proc commit*(t: Transaction; idempotencyKey = ""): seq[JsonNode] =
  ## Send all staged operations atomically and return the per-operation
  ## results. `idempotencyKey`, when non-empty, makes the commit safe to retry
  ## — the daemon returns the original response on duplicate commits, even
  ## after a crash.
  ##
  ## Raises `ValueError` if called twice on the same transaction;
  ##     `ConflictError` if a constraint violation rolled back the batch.
  if t.committed:
    raise newException(ValueError, alreadyCommittedMsg)
  t.committed = true
  if t.ops.len == 0:
    return @[]
  return t.client.commitTxn(t.ops, idempotencyKey)

proc rollback*(t: Transaction) =
  ## Discard all staged operations. Raises `ValueError` if the transaction was
  ## already committed.
  if t.committed:
    raise newException(ValueError, alreadyCommittedMsg)
  t.ops = @[]
  t.committed = true
