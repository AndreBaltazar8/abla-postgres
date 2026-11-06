ABLAC ?= ablac
COMPILER := $(ABLAC)

.PHONY: check test

check:
	mkdir -p build
	$(COMPILER) build tests/host_address_test.ab -o build/host-address-test --fast --no-cache
	build/host-address-test
	$(COMPILER) build tests/crypto_test.ab -o build/crypto-test --fast --no-cache
	build/crypto-test
	$(COMPILER) build tests/protocol_test.ab -o build/protocol-test --fast --no-cache
	$(COMPILER) build tests/transaction_test.ab -o build/transaction-test --fast --no-cache
	$(COMPILER) build tests/auth_deadline_test.ab -o build/auth-deadline-test --fast --no-cache
	build/auth-deadline-test
	$(COMPILER) build tests/pool_cache_test.ab -o build/pool-cache-test --fast --no-cache
	build/pool-cache-test

test:
	./tools/test-postgres.sh
