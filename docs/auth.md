# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) — no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) — every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) — every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The Nim client supports all three through `newMongrelDB` keyword arguments.
This guide shows each mode and how to manage users and roles via SQL when the
server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with the `token` argument. It is sent as `Authorization: Bearer ...`
on every request:

```nim
let db = newMongrelDB("http://127.0.0.1:8453", token = "s3cret-token")

if db.health():
  echo "healthy"
```

A missing or wrong token surfaces as `AuthError` (HTTP 401/403).

### Where the token comes from

Hard-coding secrets in source is bad practice. Read it from the environment:

```nim
import std/os

let token = getEnv("MONGRELDB_TOKEN")
if token.len == 0:
  echo "MONGRELDB_TOKEN not set"
  quit(1)
let db = newMongrelDB("http://127.0.0.1:8453", token = token)
```

## Basic auth mode

Start the daemon with a users file or inline users:

```sh
mongreldb-server --auth-users
```

Connect with `username` / `password`:

```nim
let db = newMongrelDB("http://127.0.0.1:8453",
    username = "admin", password = "s3cret")
```

The client base64-encodes `username:password` and sets
`Authorization: Basic ...` on every request.

## Token takes precedence

If you supply both, `token` wins and Basic credentials are ignored. This lets
you layer an override without branching:

```nim
let db = newMongrelDB(url,
    token = "overrides-everything", # token wins
    username = "fallback",
    password = "user")
```

## Per-request timeout

`setTimeout(ms)` sets the timeout for every request (default 30000 ms). It
mutates the client in place and returns it, so it chains off construction:

```nim
var db = newMongrelDB("http://127.0.0.1:8453")
discard db.setTimeout(60_000)
```

Note that `setTimeout` requires a `var MongrelDB`, so bind the client to a
`var` before calling it.

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `db.sql`.

### Create a user

```nim
discard db.sql("CREATE USER alice WITH PASSWORD 'hunter2'")
```

Passwords are Argon2id-hashed by the daemon before storage.

### Alter a user

Change a password:

```nim
discard db.sql("ALTER USER alice WITH PASSWORD 'new-password'")
```

Grant the admin role:

```nim
discard db.sql("ALTER USER alice ADMIN")
```

`ALTER USER ... ADMIN` is how you promote a user to full administrative
privileges (table creation/drop, compaction, user management). Use it
sparingly.

### Drop a user

```nim
discard db.sql("DROP USER alice")
```

### Roles and grants

```nim
discard db.sql("CREATE ROLE analyst")
discard db.sql("GRANT SELECT ON orders TO analyst")
discard db.sql("GRANT analyst TO alice")
discard db.sql("REVOKE SELECT ON orders FROM analyst")
discard db.sql("DROP ROLE analyst")
```

Exact grant syntax mirrors the server's SQL flavor; consult the server's SQL
reference for the full `GRANT`/`REVOKE` grammar available in your build.

## Common pitfalls

**Auth errors look like other errors without a typed `except`.** A 401/403
maps to `AuthError`; a 404 maps to `NotFoundError`. Always catch the specific
type rather than string-matching messages.

**Forgetting to set auth in production.** A client built with the default
constructor sends no credentials. Against an auth-enabled daemon, every call
raises `AuthError`. Centralize client construction so the auth arguments are
never accidentally dropped.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

**Mixing modes.** The daemon's auth mode is fixed at startup. A bearer token
against a Basic-auth daemon (or vice versa) will not work.

## Next steps

- [errors.md](errors.md) — `AuthError` and the rest of the hierarchy
- [quickstart.md](quickstart.md) — the full end-to-end walkthrough
