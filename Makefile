ABLAC_DIR := $(abspath ../ablac)
COMPILER := $(ABLAC_DIR)/build/ablac

.PHONY: check test

check:
	mkdir -p build
	$(COMPILER) build tests/crypto_test.ab -o build/crypto-test --fast --no-cache
	build/crypto-test
	$(COMPILER) build tests/protocol_test.ab -o build/protocol-test --fast --no-cache

test:
	./tools/test-postgres.sh
