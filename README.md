# Abla Postgres

`POSTGRES_HOST` accepts ordered comma-separated IPv4/DNS candidates, with an
optional `:port` per candidate (otherwise `POSTGRES_PORT`). Authentication,
TLS, and a writable-target probe share one connect deadline across candidates;
`POSTGRES_TARGET_SESSION_ATTRS=any` explicitly permits read-only connections.
The default is `read-write`. Async pool callers must supply `resolvedCandidates` for DNS names from a resolver outside the event loop; uncached names are refused immediately rather than blocking `query()` or `step(0)`. Numeric addresses and localhost need no lookup. A `25006` read-only error discards that session and
fails the operation; a later independent operation can select a writer. No SQL
is replayed during failover. `pgConfigWithTimeouts` retains this policy when
giving a checkpoint connection a separate budget. The bounded connector uses
IPv4/DNS and `/etc/hosts`, without invoking arbitrary blocking NSS resolvers.

For an SSH tunnel, the optional trailing `PgConfig.hostAddress` can set an
IPv4 TCP destination while `host` stays the logical DNS name used by verify-full
TLS and SNI. For example, use `host="pg.example.test"`, `port=55472`,
`hostAddress="127.0.0.1"`, `sslMode="verify-full"` and the server CA.
The override accepts exactly one logical host and a numeric IPv4 address;
malformed addresses, IPv6 and multi-host overrides are refused. Empty (the
default) retains ordinary resolution and multi-host behavior. Sync clients,
async pools and timeout/candidate copies preserve this separation; an explicit
override takes precedence over an async off-loop address cache. No TLS policy
is weakened, and this constructor field does not introduce an ambient
`PGHOSTADDR` environment override.

Abla Postgres is a PostgreSQL client written in
[Abla](https://github.com/AndreBaltazar8/ablac) for Abla Linux services. It
speaks the PostgreSQL v3 wire protocol directly, so applications do not need
`libpq`, a C wrapper, or a language-specific sidecar.

The current release includes:

- extended-protocol parameterized queries (`$1`, `$2`, ...);
- text and `NULL` parameters;
- named, nullable result cells;
- connection and read timeouts;
- reusable authenticated sessions for low-latency services;
- PostgreSQL server errors, SQLSTATE and explicit uncertain commit outcomes;
- transaction state retained across transport failures, including the session bridge;
- trust, cleartext password, MD5 challenge-response, and SCRAM-SHA-256
  authentication;
- RFC-compatible SHA-256/HMAC/PBKDF2 proofs from `abla/crypto`, with server-signature
  verification;
- TLS, by its own import so that only programs using it link OpenSSL; 
- environment-based configuration; and
- numeric IPv4 plus Docker/Icy service-name resolution.

## Import

`abla-postgres` is an Abla package whose entry point is `src/postgres.ab`.
Once your project has locked the GitHub dependency, import it with:

```abla
import github("AndreBaltazar8/abla-postgres")
```

During sibling-checkout development, import it directly:

```abla
import "../../abla-postgres/src/postgres.ab"
```


## TLS

`import github("AndreBaltazar8/abla-postgres/tls")` and a call to `pgTlsEnable()` add it, and then
a `PgConfig`'s `sslMode` and `sslRootCert`, or `POSTGRES_SSLMODE` and `POSTGRES_SSLROOTCERT`, ask for it:

- `disable`, the default: plain;
- `require`: encrypted, with no check of who answers;
- `verify-ca`: the certificate chains to the CA file in `sslRootCert` (or `system`);
- `verify-full`: that, and it names `host`, as a name or as an address.

There's no fallback: a server without TLS, a certificate that doesn't check out, or a program that asks without
having added it gets an error, not a plain connection. Without the import a program links no OpenSSL. The async pool uses the same TLS policy through nonblocking SSLRequest, handshake, authentication and query states. `detachConnection(slot)` transfers both the fd and its TLS handle for a dedicated LISTEN connection; copying only an fd is insufficient. A pool can receive `resolvedCandidates` from an off-loop resolver while retaining the original host names for certificate checks.

## Querying

Configuration follows the variables used by the official PostgreSQL image:

```sh
POSTGRES_HOST=database
POSTGRES_PORT=5432
POSTGRES_DB=my_app
POSTGRES_USER=postgres
POSTGRES_PASSWORD=change-me
```

For Docker/Icy secrets, set `POSTGRES_PASSWORD_FILE` to the mounted secret
path instead. A direct `POSTGRES_PASSWORD` takes precedence.

`POSTGRES_CONNECT_TIMEOUT_MS` and `POSTGRES_READ_TIMEOUT_MS` are optional and
default to 3000 and 5000 milliseconds. The read timeout is how long the client
waits for the next bytes of a reply, so a query that takes longer than it fails
unless the query gives its own: `client.query(sql, parameters, 60000)`, and
likewise as the last argument of `execute`, `pgQuery`, `pgExecute`,
`pgSessionQuery` and, on a pool, `query` and `execute`. A query that runs out
loses its connection. Outside an explicit transaction, the next operation can open
another; statements are never automatically replayed. PostgreSQL may keep
working on it, so set `statement_timeout` where that matters. A single message
over 16 MiB is refused with an error that says so, and also loses its connection.

```abla
import github("AndreBaltazar8/abla-postgres")

fun main: int {
    val database = pgClient(pgConfigFromEnvironment())
    val found = database.query(
        "SELECT id::text AS id, email FROM users WHERE email = \$1",
        [pgText("alex@example.com")]
    )
    database.close()
    if (!found.succeeded) {
        // found.error contains a bounded connection, protocol, or server error.
        1
    } else if (found.rows.size == 0) 2
    else if (found.first("email") == "alex@example.com") 0
    else 3
}
```

The dollar sign is escaped in Abla source (`\$1`) so that PostgreSQL receives
the literal placeholder. Values remain separate protocol fields and are never
concatenated into SQL.

For a long-running single-threaded service, retain a `PgClient` locally and use
`client.query(...)` or `client.execute(...)` for consecutive operations. It
authenticates lazily on the first query and reuses that connection until
`client.close()` or a transport failure. `pgQuery(config, ...)` and
`pgExecute(config, ...)` remain convenient one-shot calls.

Abla deliberately prevents mutable borrowing of a managed global. Servers that
need a process-wide session retain an immutable `PgSessionState` and replace it
with each returned state:

```abla
val first = pgSessionQuery(config, PgSessionState(), "BEGIN")
val written = pgSessionQuery(config, first.state, "UPDATE items SET ready=true")
val ended = pgSessionQuery(config, written.state, "COMMIT")
```

The bridge now requires the complete state instead of separate descriptor and
buffer arguments. Check every result before proceeding or reporting success.
Migrate existing callers to retain `reply.state`, including on
failure. It contains `descriptor`, `buffered`, and `transactionState`; retaining
only the socket loses the distinction between a fresh session and a disconnected
transaction. A server can also retain these three scalar fields separately and
construct the next `PgSessionState` from them.

### Transaction loss and uncertain outcomes

`BEGIN`/`START TRANSACTION` and PostgreSQL's `ReadyForQuery` transaction state
are tracked. Losing the connection during an open transaction, or before BEGIN
is fully acknowledged, makes later statements and COMMIT fail without opening a
replacement connection. Explicit `ROLLBACK` or `client.close()` resets that
logical session; a bridge caller must carry the reset's returned state. Calling
`connect()` cannot silently abandon a live transaction.

Always check COMMIT's result. PostgreSQL reports an aborted transaction's COMMIT
as a `ROLLBACK` command; the client returns `succeeded=false` and SQLSTATE `25P02`
for that case. Ordinary SQL errors retain their server SQLSTATE and drain the
protocol so rollback remains possible.

If a COMMIT acknowledgement is lost, `result.outcomeUnknown` is true. The write
may have committed: resolve it using application idempotency or a durable
operation identity before retrying. A subsequent local ROLLBACK resets the
disconnected client but returns failure with `outcomeUnknown=true`; it does not
claim the original commit rolled back. An interrupted simple-query script is
conservative for the same reason. An interrupted autocommitted request can also
have an unknown outcome, even though a later independent operation may reconnect.

The asynchronous pool follows the same rule: a running COMMIT with a lost reply
is uncertain, while an unsent queued COMMIT is not. A failed transaction's queued
operations fail together, and its transaction ID cannot be revived on a different
connection. Neither client replays database statements automatically.
Use the pool's `begin()`, `commit()` and `rollback()` methods for transaction
boundaries; raw boundary SQL through `pool.query()` is refused. After connection
loss, `ROLLBACK AND CHAIN` is refused rather than claiming a new transaction
started on a missing connection; use a simple rollback/reset, then a fresh BEGIN.

Use `pgNull()` for a SQL null value:

```abla
val result = pgExecute(
    pgConfigFromEnvironment(),
    "UPDATE profiles SET nickname = \$1 WHERE user_id = \$2",
    [pgNull(), pgText("42")]
)
```

Useful result APIs are:

- `result.succeeded`, `result.error`, `result.sqlState`, `result.command`, and `result.outcomeUnknown`;
- `result.columns` and `result.rows`;
- `result.first("column")` for the first non-null string value; and
- `result.cell(row, "column")`, which returns a `PgValue` with `value` and
  `isNull`.

All PostgreSQL values currently use text format. `pgInt(value)` is provided as
a small checked decimal conversion helper.

## Icy deployment

Keep PostgreSQL private and give the Abla service the internal Icy DNS name:

```jsonnet
{
  name: 'my-app',
  machine: 'oxente',
  targets: {
    production: {
      envs: {
        POSTGRES_HOST: 'my-app_database',
        POSTGRES_DB: 'my_app',
        POSTGRES_USER: 'postgres',
        POSTGRES_HOST_AUTH_METHOD: 'scram-sha-256',
      },
      services: {
        api: {
          type: 'abla-prebuilt',
          object_path: 'build/server-prebuilt.o',
          port: 8080,
          envs: [
            'POSTGRES_HOST',
            'POSTGRES_DB',
            'POSTGRES_USER',
            'POSTGRES_PASSWORD_FILE',
          ],
        },
        database: {
          type: 'postgres',
          envs: [
            'POSTGRES_DB',
            'POSTGRES_HOST_AUTH_METHOD',
            'POSTGRES_PASSWORD_FILE',
          ],
        },
      },
    },
  },
}
```

Place `POSTGRES_PASSWORD_FILE: <strong password>` in
`secrets/production.yaml`; Icy mounts it and provides its path to both
services. Icy addresses the database as `<project>_<service>`, hence
`my-app_database`. The Postgres service template supplies a persistent
`pgdata` volume. Do not set `published_port` or `expose_ports` in production.

See [Icy deployment notes](docs/icy.md) and the
[wire-protocol design](docs/protocol.md) for more detail.

## Build and test

Use an installed released compiler (`ablac` on PATH, or `ABLAC=/path/to/ablac`).
A compiler-only check is:

```sh
make check
```

The integration test starts temporary `postgres:16-alpine` containers on
random loopback ports. It verifies trust, cleartext password, actual legacy
MD5, and SCRAM-SHA-256 authentication, rejects wrong passwords for every
password mode, exercises parameterized write/read and null decoding, and
removes every container. It also checks killed transaction backends, loss of
BEGIN/COMMIT acknowledgements, persisted uncertain commits, the scalar bridge,
and asynchronous transaction queues:

```sh
make test
```

Set `ABLAC=/path/to/ablac` to select a different compiler binary.

## Security and current scope

Use `scram-sha-256` for new deployments. SCRAM validates the server proof and
never transmits the password. MD5 is implemented for compatibility but is
deprecated by PostgreSQL. Cleartext `password` authentication should only be
used over TLS. `trust` is
appropriate only for tightly controlled test networks.

SCRAM-SHA-256-PLUS requires TLS channel binding and is therefore not offered
until TLS lands. GSSAPI, SSPI, LDAP, PAM, peer, and certificate authentication
are server/infrastructure mechanisms rather than PostgreSQL password exchanges
and are outside this client module.

One-shot helpers open one bounded connection per call. `PgClient` and
`pgSessionQuery` reuse an authenticated connection and drain ordinary SQL
errors through `ReadyForQuery`, while transport failures invalidate the session
and preserve explicit transaction loss. Prepared statement reuse, binary values,
and cancellation remain future additions.

## License

Abla Postgres is licensed under the [Mozilla Public License 2.0](LICENSE).

Authentication frames are limited to64KiB. Connection deadlines include CPU derivation, startup/password/SASL writes, TLS reads/handshake and teardown. Pre-detach NOTIFY frames are retained with a256KiB per-connection bound and transferred before any partial input frame.
