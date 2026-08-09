# Deploying with Icy

The supported 0.1 deployment shape is one private Icy PostgreSQL service and
one Abla service on the same overlay network.

Use the generated service name as `POSTGRES_HOST`. For a project named
`abla-food` and a service named `database`, that name is
`abla-food_database`.

The Postgres service must use `POSTGRES_HOST_AUTH_METHOD=trust` until the
client implements SCRAM. This is acceptable only when all of the following
remain true:

- the service has no published port;
- only trusted workloads join the overlay network;
- the database container and Icy deployment are access controlled; and
- backups and operational access are handled separately.

The application should run idempotent migrations before serving data or use a
dedicated migration executable. The Mimo sample currently demonstrates the
former so that a new Icy volume can bootstrap without another runtime.

The `abla-prebuilt` Alpine image includes the platform resolver used for Icy
service-name lookup. Numeric IPv4 hosts skip that process entirely.
