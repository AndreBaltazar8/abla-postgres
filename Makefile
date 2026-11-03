ABLAC ?= ablac
COMPILER := $(ABLAC)

.PHONY: check test

check:
	mkdir -p build
	$(COMPILER) build tests/crypto_test.ab -o build/crypto-test --fast --no-cache
	build/crypto-test
	$(COMPILER) build tests/protocol_test.ab -o build/protocol-test --fast --no-cache
	$(COMPILER) build tests/transaction_test.ab -o build/transaction-test --fast --no-cache

test:
	./tools/test-postgres.sh
