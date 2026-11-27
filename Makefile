ABLAC ?= ablac
COMPILER := $(ABLAC)

.PHONY: check test

check:
	mkdir -p build
	$(COMPILER) build tests/host_address_test.ab -o build/host-address-test --fast --no-cache
	build/host-address-test
	$(COMPILER) build tests/crypto_test.ab -o build/crypto-test --fast --no-cache
	build/crypto-test
	$(COMPILER) build tests/channel_binding_test.ab -o build/channel-binding-test --fast --no-cache
	build/channel-binding-test
	$(COMPILER) build tests/protocol_test.ab -o build/protocol-test --fast --no-cache
	$(COMPILER) build tests/transaction_test.ab -o build/transaction-test --fast --no-cache
	$(COMPILER) build tests/pipeline_test.ab -o build/pipeline-test --fast --no-cache
	build/pipeline-test fake-only
	$(COMPILER) build tests/auth_deadline_test.ab -o build/auth-deadline-test --fast --no-cache
	build/auth-deadline-test
	$(COMPILER) build tests/result_limit_test.ab -o build/result-limit-test --fast --no-cache
	build/result-limit-test
	$(COMPILER) build tests/password_auth_test.ab -o build/password-auth-test --fast --no-cache
	build/password-auth-test
	$(COMPILER) build tests/prefer_test.ab -o build/prefer-test --fast --no-cache
	build/prefer-test
	$(COMPILER) build tests/pool_cache_test.ab -o build/pool-cache-test --fast --no-cache
	build/pool-cache-test

test:
	./tools/test-postgres.sh

# Optional until the compiler release containing abla/sql is installed.
.PHONY: test-sql
test-sql:
	ABLAC=$(COMPILER) ./tools/test-sql.sh
