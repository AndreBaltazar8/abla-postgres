#!/usr/bin/env sh
# Optional adapter test; requires a compiler whose stdlib includes abla/sql.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${ABLAC:-ablac}
container="abla-postgres-checked-sql-$$"
cleanup() { docker stop "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
mkdir -p "$root/build"
"$compiler" build "$root/tests/sql_test.ab" -o "$root/build/sql-test" --fast --no-cache
docker run -d --rm --name "$container" -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=abla_test -p 127.0.0.1::5432 postgres:16-alpine >/dev/null
port=$(docker port "$container" 5432/tcp | sed 's/.*://')
attempt=0
until docker exec "$container" pg_isready -U postgres -d abla_test >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || exit 1
    sleep 1
done
POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test POSTGRES_USER=postgres "$root/build/sql-test"
