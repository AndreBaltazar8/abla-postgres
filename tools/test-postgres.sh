#!/usr/bin/env sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${ABLAC:-ablac}
password='abla-postgres-test-password'
containers=''

cleanup() {
    for container in $containers; do
        docker stop "$container" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT INT TERM

mkdir -p "$project_dir/build"
"$compiler" build "$project_dir/tests/host_address_test.ab" -o "$project_dir/build/host-address-test" --fast --no-cache
"$project_dir/build/host-address-test"
"$compiler" build "$project_dir/tests/protocol_test.ab" \
    -o "$project_dir/build/protocol-test" --fast --no-cache
"$compiler" build "$project_dir/tests/auth_failure_test.ab" \
    -o "$project_dir/build/auth-failure-test" --fast --no-cache
"$compiler" build "$project_dir/tests/transaction_test.ab" \
    -o "$project_dir/build/transaction-test" --fast --no-cache
"$compiler" build "$project_dir/tests/pipeline_test.ab" \
    -o "$project_dir/build/pipeline-test" --fast --no-cache
"$compiler" build "$project_dir/tests/async_test.ab" \
    -o "$project_dir/build/async-test" --fast --no-cache
"$compiler" build "$project_dir/tests/hosts_test.ab" \
    -o "$project_dir/build/hosts-test" --fast --no-cache

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
    until docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -d abla_test >/dev/null 2>&1; do
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

    POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test \
    POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" \
        "$project_dir/build/transaction-test"

    POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test \
    POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" \
        "$project_dir/build/pipeline-test"

    if [ "$mode" != trust ]; then
        # The existing pool regression uses42 as its successful process result.
        pool_status=0
        POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test \
        POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" \
            "$project_dir/build/async-test" || pool_status=$?
        if [ "$pool_status" -ne 42 ]; then echo "async pool failed: $pool_status"; exit 1; fi
        POSTGRES_HOST=127.0.0.1 \
        POSTGRES_PORT="$port" \
        POSTGRES_DB=abla_test \
        POSTGRES_USER=postgres \
        POSTGRES_PASSWORD=definitely-wrong \
            "$project_dir/build/auth-failure-test"
    fi

    if [ "$mode" = trust ]; then
        reader="abla-postgres-reader-$$"
        containers="$containers $reader"
        docker run -d --rm --name "$reader" -e POSTGRES_HOST_AUTH_METHOD=trust \
            -e POSTGRES_DB=abla_test -p 127.0.0.1::5432 postgres:16-alpine >/dev/null
        reader_port=$(docker port "$reader" 5432/tcp | sed 's/.*://')
        attempt=0
        until docker exec "$reader" pg_isready -h 127.0.0.1 -U postgres -d abla_test >/dev/null 2>&1; do
            attempt=$((attempt+1))
            if [ "$attempt" -ge 30 ]; then exit 1; fi
            sleep 1
        done
        docker exec "$reader" psql -U postgres -d abla_test -v ON_ERROR_STOP=1 \
            -c 'ALTER DATABASE abla_test SET default_transaction_read_only=on' >/dev/null
        POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test \
            POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" PG_TEST_READONLY_PORT="$reader_port" \
            "$project_dir/build/hosts-test"
        docker stop "$reader" >/dev/null
        containers=$(printf '%s' "$containers" | sed "s/ $reader//")
    fi

    docker stop "$container" >/dev/null
    containers=$(printf '%s' "$containers" | sed "s/ $container//")
    echo "abla-postgres: $mode authentication passed"
}

if [ "${PG_TEST_TLS_ONLY:-}" != 1 ]; then
    run_mode trust scram-sha-256
    run_mode password scram-sha-256
    run_mode md5 md5
    run_mode scram-sha-256 scram-sha-256
fi

# What asks for TLS gets it, checked as asked, or a refusal: never a plain connection.
run_tls() {
    "$compiler" build "$project_dir/tests/tls_test.ab" -o "$project_dir/build/tls-test" --fast --no-cache
    "$compiler" build "$project_dir/tests/async_tls_test.ab" -o "$project_dir/build/async-tls-test" --fast --no-cache
    "$compiler" build "$project_dir/tests/no_tls_test.ab" -o "$project_dir/build/no-tls-test" --fast --no-cache
    "$project_dir/build/no-tls-test" >/dev/null
    if ldd "$project_dir/build/no-tls-test" | grep -q ssl; then echo 'a program without the tls subpath links OpenSSL'; exit 1; fi

    work=$(mktemp -d)
    cert() { # NAME CA SAN
        openssl req -new -newkey rsa:2048 -nodes -keyout "$work/$1.key" -out "$work/$1.csr" -subj "/CN=$1" 2>/dev/null
        printf 'subjectAltName=%s\n' "$3" > "$work/$1.ext"
        openssl x509 -req -in "$work/$1.csr" -CA "$work/$2.pem" -CAkey "$work/$2.key" -CAcreateserial -days 2 -extfile "$work/$1.ext" -out "$work/$1.pem" 2>/dev/null
    }
    for ca in ca other; do
        openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/$ca.key" -out "$work/$ca.pem" -days 2 -subj "/CN=$ca" 2>/dev/null
    done
    cert server ca DNS:localhost
    cert address ca IP:127.0.0.1
    cert tunnel ca DNS:pg-tunnel.example.test

    container="abla-postgres-tls-$$"
    containers="$containers $container"
    docker run -d --rm --name "$container" -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=abla_test -p 127.0.0.1::5432 postgres:16-alpine >/dev/null
    port=$(docker port "$container" 5432/tcp | sed 's/.*://')
    until docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -d abla_test >/dev/null 2>&1; do sleep 1; done
    expect() { # WHAT SSLMODE ROOT HOST
        for program in tls-test async-tls-test; do
            got=$(POSTGRES_HOST="$4" POSTGRES_PORT="$port" POSTGRES_DB=abla_test POSTGRES_USER=postgres POSTGRES_SSLMODE="$2" POSTGRES_SSLROOTCERT="$3" PG_TEST_HOST_ADDRESS="${5:-}" "$project_dir/build/$program" 2>&1 || true)
            case "$got" in
                $1*) echo "ok   $program $2 $4 ${3##*/}: $1" ;;
                *) echo "FAIL $program $2 $4 ${3##*/}: wanted $1, got $got"; exit 1 ;;
            esac
        done
    }
    # With TLS off on the server.
    expect plain disable '' 127.0.0.1
    expect refused require '' 127.0.0.1
    expect refused verify-full "$work/ca.pem" localhost

    use() {
        docker cp "$work/$1.pem" "$container:/tmp/server.pem" >/dev/null
        docker cp "$work/$1.key" "$container:/tmp/server.key" >/dev/null
        docker exec "$container" chown postgres /tmp/server.pem /tmp/server.key
        docker exec "$container" chmod 600 /tmp/server.key
        docker exec "$container" psql -U postgres -d abla_test -Atc "ALTER SYSTEM SET ssl=on" -c "ALTER SYSTEM SET ssl_cert_file='/tmp/server.pem'" -c "ALTER SYSTEM SET ssl_key_file='/tmp/server.key'" -c 'SELECT pg_reload_conf()' >/dev/null
        sleep 1
    }
    use server
    expect plain disable '' 127.0.0.1
    expect ssl require '' 127.0.0.1
    expect ssl verify-ca "$work/ca.pem" 127.0.0.1
    expect ssl verify-full "$work/ca.pem" localhost
    expect refused verify-ca "$work/other.pem" localhost
    expect refused verify-full "$work/other.pem" localhost
    expect refused verify-full "$work/ca.pem" 127.0.0.1
    expect refused verify-ca '' localhost
    expect refused verify-ca "$work/missing.pem" localhost
    expect refused nonsense '' localhost
    use tunnel
    expect ssl verify-full "$work/ca.pem" pg-tunnel.example.test 127.0.0.1
    expect refused verify-full "$work/ca.pem" wrong-tunnel.example.test 127.0.0.1
    expect refused verify-full "$work/other.pem" pg-tunnel.example.test 127.0.0.1
    expect refused verify-full "$work/ca.pem" pg-tunnel.example.test localhost
    expect refused verify-full "$work/ca.pem" 'pg-tunnel.example.test,localhost' 127.0.0.1
    use address
    expect ssl verify-full "$work/ca.pem" 127.0.0.1
    expect refused verify-full "$work/ca.pem" localhost

    docker stop "$container" >/dev/null
    containers=$(printf '%s' "$containers" | sed "s/ $container//")
    rm -r "$work"
    echo "abla-postgres: TLS passed"
}
run_tls

echo "abla-postgres: all PostgreSQL 16 integration tests passed"
