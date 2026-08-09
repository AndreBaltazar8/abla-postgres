# Wire-protocol design

Abla Postgres implements PostgreSQL protocol version 3 over Abla's bounded
Linux TCP transport.

For every `pgQuery` or `pgExecute` call it:

1. resolves a numeric address directly or a Docker/Icy service name through
   the container resolver;
2. establishes a connection with a bounded timeout;
3. sends a startup message containing `user`, `database`, and
   `application_name`;
4. completes trust, cleartext password, MD5, or SCRAM-SHA-256 authentication
   and waits for `AuthenticationOk` and `ReadyForQuery`;
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

SCRAM nonces come from `/dev/urandom`. The client validates the server nonce
prefix, Base64 salt, a bounded iteration count, and the final server signature.
SHA-256, HMAC-SHA-256, PBKDF2, Base64, and proof XOR are implemented in Abla
and covered by RFC and independent test vectors. MD5 uses PostgreSQL's nested
`md5(md5(password + user) + salt)` challenge construction.

## Planned protocol work

- TLS negotiation and certificate verification.
- SCRAM-SHA-256-PLUS channel binding after TLS is available.
- Transaction and connection-scoped callback APIs.
- Connection pooling and prepared statement reuse.
- Binary parameter/result codecs.
- PostgreSQL cancellation messages.
