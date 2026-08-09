# Abla Postgres

Abla Postgres is a PostgreSQL client written in
[Abla](https://github.com/AndreBaltazar8/ablac) for Abla Linux services. It
speaks the PostgreSQL v3 wire protocol directly, so applications do not need
`libpq`, a C wrapper, or a language-specific sidecar.

The current release includes:

- extended-protocol parameterized queries (`$1`, `$2`, ...);
- text and `NULL` parameters;
- named, nullable result cells;
- connection and read timeouts;
- PostgreSQL server error propagation;
- trust, cleartext password, MD5 challenge-response, and SCRAM-SHA-256
  authentication;
- RFC-compatible SHA-256/HMAC/PBKDF2 proofs with server-signature
  verification;
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
default to 3000 and 5000 milliseconds.

```abla
import github("AndreBaltazar8/abla-postgres")

fun findUser(email: string): PgResult {
    val database = pgConfigFromEnvironment()
    pgQuery(
        database,
        "SELECT id::text AS id, email FROM users WHERE email = \$1",
        [pgText(email)]
    )
}

fun main: int {
    val found = findUser("alex@example.com")
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

Use `pgNull()` for a SQL null value:

```abla
val result = pgExecute(
    pgConfigFromEnvironment(),
    "UPDATE profiles SET nickname = \$1 WHERE user_id = \$2",
    [pgNull(), pgText("42")]
)
```

Useful result APIs are:

- `result.succeeded`, `result.error`, and `result.command`;
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

Build `../ablac` first. A compiler-only check is:

```sh
make check
```

The integration test starts temporary `postgres:16-alpine` containers on
random loopback ports. It verifies trust, cleartext password, actual legacy
MD5, and SCRAM-SHA-256 authentication, rejects wrong passwords for every
password mode, exercises parameterized write/read and null decoding, and
removes every container:

```sh
make test
```

Set `ABLAC=/path/to/ablac` to select a different compiler binary.

## Security and current scope

Use `scram-sha-256` for new deployments. SCRAM validates the server proof and
never transmits the password. MD5 is implemented for compatibility but is
deprecated by PostgreSQL. Cleartext `password` authentication should only be
used over TLS; Abla Postgres does not provide TLS transport yet. `trust` is
appropriate only for tightly controlled test networks.

SCRAM-SHA-256-PLUS requires TLS channel binding and is therefore not offered
until TLS lands. GSSAPI, SSPI, LDAP, PAM, peer, and certificate authentication
are server/infrastructure mechanisms rather than PostgreSQL password exchanges
and are outside this client module.

Each query currently opens one bounded connection. This prioritizes a small,
auditable implementation and correct failure behavior; pooling, prepared
statement reuse, transactions, binary values, and cancellation are future
additions.

## License

Abla Postgres is licensed under the [Mozilla Public License 2.0](LICENSE).
