#!/usr/bin/env sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${ABLAC:-ablac}
password='abla-postgres-test-password'
containers=''
relays=''

cleanup() {
    for pid in ${relays:-}; do kill "$pid" 2>/dev/null || true; done
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
"$compiler" build "$project_dir/tests/cache_test.ab" \
    -o "$project_dir/build/cache-test" --fast --no-cache
"$compiler" build "$project_dir/tests/async_test.ab" \
    -o "$project_dir/build/async-test" --fast --no-cache
"$compiler" build "$project_dir/tests/binding_test.ab" -o "$project_dir/build/binding-test" --fast --no-cache
"$compiler" build "$project_dir/tests/channel_binding_test.ab" -o "$project_dir/build/channel-binding-test" --fast --no-cache
"$project_dir/build/channel-binding-test"
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

    # The same transaction rules with the statement cache on, and the cache's own checks.
    POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test \
    POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" PG_TEST_STATEMENT_CACHE=1 \
        "$project_dir/build/transaction-test"
    POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test \
    POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" PG_TEST_STATEMENT_CACHE=1 \
        "$project_dir/build/pipeline-test"
    POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test \
    POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" \
        "$project_dir/build/cache-test"

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

    # channel_binding=require over a connection without TLS: refused, for each way the server authenticates (the SCRAM of
    # a server that offers PLUS needs TLS); prefer and disable authenticate as always.
    case "$mode" in
        scram-sha-256) want='TLS is not in use' ;;
        *) want='authenticated the client without channel binding' ;;
    esac
    for policy in require prefer disable; do
        got=$(POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$port" POSTGRES_DB=abla_test POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" \
            POSTGRES_CHANNEL_BINDING="$policy" "$project_dir/build/binding-test" 2>&1 || true)
        case "$policy:$got" in
            require:*"$want"*) ;;
            prefer:ok|disable:ok) ;;
            *) echo "FAIL $mode channel_binding=$policy without TLS: $got"; exit 1 ;;
        esac
    done

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

if [ "${PG_TEST_TLS_ONLY:-}" != 1 ] && [ "${PG_TEST_BINDING_ONLY:-}" != 1 ]; then
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
    for program in tls-test async-tls-test no-tls-test; do if ldd "$project_dir/build/$program" 2>/dev/null | grep -q 'ssl\|crypto'; then echo "$program links OpenSSL"; exit 1; fi; done

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
    # sslrootcert=system is the system trust store, which abla/tls/pure reads from SSL_CERT_FILE (pureTlsSessionStore): the CA of
    # the server is trusted through it, another CA is not.
    SSL_CERT_FILE="$work/ca.pem" expect ssl verify-full system localhost
    SSL_CERT_FILE="$work/other.pem" expect refused verify-full system localhost
    SSL_CERT_FILE="$work/ca.pem" expect ssl verify-ca system localhost
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
[ "${PG_TEST_BINDING_ONLY:-}" = 1 ] || run_tls

# SCRAM-SHA-256-PLUS (channel_binding): against PostgreSQL itself, and against a relay that terminates TLS in between.
run_binding() {
    "$compiler" build "$project_dir/tests/binding_test.ab" -o "$project_dir/build/binding-test" --fast --no-cache
    "$compiler" build "$project_dir/tests/binding_relay.ab" -o "$project_dir/build/binding-relay" --fast --no-cache
    work=$(mktemp -d)
    for name in server attacker; do
        openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/$name.key" -out "$work/$name.pem" -days 2 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
    done
    container="abla-postgres-binding-$$"
    containers="$containers $container"
    docker run -d --rm --name "$container" -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=abla_test -p 127.0.0.1::5432 postgres:16-alpine >/dev/null
    port=$(docker port "$container" 5432/tcp | sed 's/.*://')
    until docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -d abla_test >/dev/null 2>&1; do sleep 1; done
    docker cp "$work/server.pem" "$container:/tmp/server.pem" >/dev/null
    docker cp "$work/server.key" "$container:/tmp/server.key" >/dev/null
    docker exec "$container" chown postgres /tmp/server.pem /tmp/server.key
    docker exec "$container" chmod 600 /tmp/server.key
    docker exec "$container" psql -U postgres -d abla_test -v ON_ERROR_STOP=1 -c "SET password_encryption='scram-sha-256'; ALTER USER postgres PASSWORD '$password';" \
        -c "ALTER SYSTEM SET ssl=on" -c "ALTER SYSTEM SET ssl_cert_file='/tmp/server.pem'" -c "ALTER SYSTEM SET ssl_key_file='/tmp/server.key'" >/dev/null
    docker exec "$container" sed -i "s/trust$/scram-sha-256/" /var/lib/postgresql/data/pg_hba.conf
    docker exec "$container" psql -U postgres -d abla_test -c 'SELECT pg_reload_conf()' >/dev/null
    sleep 1

    free_port() {
        while :; do
            candidate=$(( 20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 20000 ))
            ss -ltn "sport = :$candidate" | grep -q LISTEN || { echo "$candidate"; return; }
        done
    }
    start_relay() { # CERT MODE: starts a relay to the server; its port is $relay_port
        relay_port=$(free_port)
        "$project_dir/build/binding-relay" "$work/$1.pem" "$work/$1.key" "$relay_port" "$port" "$2" >"$work/relay-$relay_port.log" 2>&1 &
        relays="$relays $!"
        until grep -q 'relay ready' "$work/relay-$relay_port.log" 2>/dev/null; do sleep 0.2; done
    }
    expect_binding() { # WHAT PORT CHANNEL_BINDING: "ok", or "refused" with a text
        got=$(POSTGRES_HOST=127.0.0.1 POSTGRES_PORT="$2" POSTGRES_DB=abla_test POSTGRES_USER=postgres POSTGRES_PASSWORD="$password" \
            POSTGRES_SSLMODE=require POSTGRES_CHANNEL_BINDING="$3" "$project_dir/build/binding-test" 2>&1 || true)
        case "$got" in
            "$1"*) echo "ok   channel_binding=$3 $4: $1" ;;
            *) echo "FAIL channel_binding=$3 $4: wanted $1, got $got"; exit 1 ;;
        esac
    }
    # The server itself offers both: each policy authenticates (require proves PLUS was used: anything else is refused).
    for policy in prefer require disable; do expect_binding ok "$port" "$policy" "direct"; done
    expect_binding "refused: Unknown PostgreSQL channel_binding" "$port" sometimes direct
    # A relay with the server's own certificate sees the same binding: nothing to catch. Used as a server that offers only PLUS.
    start_relay server plus-only; same=$relay_port
    expect_binding ok "$same" prefer "PLUS-only server"
    expect_binding ok "$same" require "PLUS-only server"
    expect_binding "refused: PostgreSQL did not offer a supported SASL mechanism" "$same" disable "PLUS-only server"
    # A man in the middle with another certificate: PostgreSQL checks the binding and refuses the relayed proof; without
    # binding the same relay gets through (which is the attack).
    start_relay attacker pass; middle=$relay_port
    expect_binding ok "$middle" disable "man in the middle"
    expect_binding "refused: SCRAM channel binding check failed" "$middle" prefer "man in the middle"
    expect_binding "refused: SCRAM channel binding check failed" "$middle" require "man in the middle"
    # The downgrade: the relay removes PLUS from the offer. "prefer" tells the server it could have bound ("y"), which the
    # server (which did offer it) refuses; "require" refuses by itself.
    start_relay server strip-plus; stripped=$relay_port
    expect_binding ok "$stripped" disable "PLUS stripped"
    expect_binding "refused: SCRAM channel binding negotiation error" "$stripped" prefer "PLUS stripped"
    expect_binding "refused: PostgreSQL channel_binding is required, but the server did not offer SCRAM-SHA-256-PLUS" "$stripped" require "PLUS stripped"

    for pid in $relays; do kill "$pid" 2>/dev/null || true; done
    relays=''
    docker stop "$container" >/dev/null
    containers=$(printf '%s' "$containers" | sed "s/ $container//")
    rm -r "$work"
    echo "abla-postgres: channel binding passed"
}
relays=''
run_binding

echo "abla-postgres: all PostgreSQL 16 integration tests passed"
