#!/usr/bin/env sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${ABLAC:-"$project_dir/../ablac/build/ablac"}
container="abla-postgres-test-$$"

cleanup() {
    docker stop "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker run -d --rm --name "$container" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -e POSTGRES_DB=abla_test \
    -p 127.0.0.1::5432 \
    postgres:16-alpine >/dev/null

port=$(docker port "$container" 5432/tcp | sed 's/.*://')
attempt=0
until docker exec "$container" pg_isready -U postgres -d abla_test >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
        docker logs "$container"
        exit 1
    fi
    sleep 1
done

mkdir -p "$project_dir/build"
"$compiler" build "$project_dir/tests/protocol_test.ab" \
    -o "$project_dir/build/protocol-test" --fast --no-cache

POSTGRES_HOST=127.0.0.1 \
POSTGRES_PORT="$port" \
POSTGRES_DB=abla_test \
POSTGRES_USER=postgres \
    "$project_dir/build/protocol-test"

echo "abla-postgres: PostgreSQL 16 integration test passed"

