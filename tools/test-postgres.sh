#!/usr/bin/env sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${ABLAC:-"$project_dir/../ablac/build/ablac"}
password='abla-postgres-test-password'
containers=''

cleanup() {
    for container in $containers; do
        docker stop "$container" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT INT TERM

mkdir -p "$project_dir/build"
"$compiler" build "$project_dir/tests/protocol_test.ab" \
    -o "$project_dir/build/protocol-test" --fast --no-cache
"$compiler" build "$project_dir/tests/auth_failure_test.ab" \
    -o "$project_dir/build/auth-failure-test" --fast --no-cache

run_mode() {
    mode=$1
    encryption=$2
    container="abla-postgres-$mode-$$"
    containers="$containers $container"

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

    if [ "$mode" != trust ]; then
        docker exec "$container" psql -U postgres -d abla_test \
            -v ON_ERROR_STOP=1 \
            -c "SET password_encryption='$encryption'; ALTER USER postgres PASSWORD '$password';" \
            >/dev/null
        docker exec "$container" sed -i "s/trust$/$mode/" \
            /var/lib/postgresql/data/pg_hba.conf
        docker exec "$container" psql -U postgres -d abla_test \
            -c 'SELECT pg_reload_conf()' >/dev/null
    fi

    POSTGRES_HOST=127.0.0.1 \
    POSTGRES_PORT="$port" \
    POSTGRES_DB=abla_test \
    POSTGRES_USER=postgres \
    POSTGRES_PASSWORD="$password" \
        "$project_dir/build/protocol-test"

    if [ "$mode" != trust ]; then
        POSTGRES_HOST=127.0.0.1 \
        POSTGRES_PORT="$port" \
        POSTGRES_DB=abla_test \
        POSTGRES_USER=postgres \
        POSTGRES_PASSWORD=definitely-wrong \
            "$project_dir/build/auth-failure-test"
    fi

    docker stop "$container" >/dev/null
    containers=$(printf '%s' "$containers" | sed "s/ $container//")
    echo "abla-postgres: $mode authentication passed"
}

run_mode trust scram-sha-256
run_mode password scram-sha-256
run_mode md5 md5
run_mode scram-sha-256 scram-sha-256

echo "abla-postgres: all PostgreSQL 16 integration tests passed"
