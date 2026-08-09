# Wire-protocol design

Abla Postgres implements PostgreSQL protocol version 3 over Abla's bounded
Linux TCP transport.

For every `pgQuery` or `pgExecute` call it:

1. resolves a numeric address directly or a Docker/Icy service name through
   the container resolver;
2. establishes a connection with a bounded timeout;
3. sends a startup message containing `user`, `database`, and
   `application_name`;
4. accepts `AuthenticationOk` and waits for `ReadyForQuery`;
5. sends `Parse`, `Bind`, `Describe`, `Execute`, and `Sync` messages;
6. decodes `RowDescription`, `DataRow`, `CommandComplete`, `ErrorResponse`, and
   `ReadyForQuery`; and
7. closes the connection on every success or error path.

Parameters and results use PostgreSQL text format. A null parameter is encoded
with length `-1`; a null result becomes `PgValue("", true)`, which distinguishes
it from an empty string.

Frames are buffered because TCP reads do not preserve PostgreSQL message
boundaries. Individual read sizes, message sizes, connection waits, and read
waits are bounded. The client rejects unsupported authentication instead of
silently treating it as success.

## Planned protocol work

- SCRAM-SHA-256 authentication.
- TLS negotiation and certificate verification.
- Transaction and connection-scoped callback APIs.
- Connection pooling and prepared statement reuse.
- Binary parameter/result codecs.
- PostgreSQL cancellation messages.

