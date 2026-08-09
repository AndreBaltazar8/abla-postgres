# Deploying with Icy

The recommended deployment is one private Icy PostgreSQL service and one Abla
service on the same overlay network, authenticated with SCRAM-SHA-256.

Use the generated service name as `POSTGRES_HOST`. For a project named
`abla-food` and service named `database`, that name is
`abla-food_database`.

Create `secrets/production.yaml` locally:

```yaml
POSTGRES_PASSWORD_FILE: a-long-random-password
```

List `POSTGRES_PASSWORD_FILE` in both services' `envs` arrays. Icy mounts the
secret and sets the environment variable to its path. The official Postgres
image and `pgConfigFromEnvironment()` both read that file.

Set these ordinary target variables:

```jsonnet
envs: {
  POSTGRES_HOST: 'abla-food_database',
  POSTGRES_DB: 'abla_food',
  POSTGRES_USER: 'postgres',
  POSTGRES_HOST_AUTH_METHOD: 'scram-sha-256',
},
```

Do not set `published_port` or `expose_ports` in production. SCRAM protects
the password and mutually verifies the proof exchange, while the private
overlay limits exposure of query traffic until TLS transport is implemented.

## Existing trust-authenticated volumes

Adding `POSTGRES_PASSWORD_FILE` does not change the password of an existing
Postgres role. Migrate without locking the application out:

1. deploy the secret to both services while the HBA method remains `trust`;
2. inside the database service, set the role password from the mounted secret
   while `password_encryption` is `scram-sha-256`;
3. change `POSTGRES_HOST_AUTH_METHOD` to `scram-sha-256`; and
4. redeploy and verify a fresh application connection.

New volumes initialize directly with the secret and SCRAM method.
