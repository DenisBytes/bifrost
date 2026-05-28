PACKAGES = bifrost

EXAMPLES = hello spawn pingpong

BIN = bin

.PHONY: build check test test-integration examples run-example clean

# build type-checks the library and compiles every example into ./bin.
build: check examples

# check runs Odin's type checker with vet and strict-style on every package.
# strict-style is bifrost's format/style gate: this Odin toolchain ships no
# `odin fmt`, so strict-style (tabs, brace placement, spacing) is what CI
# enforces.
check:
	@for pkg in $(PACKAGES); do \
		echo "==> odin check $$pkg"; \
		odin check $$pkg -vet -strict-style -no-entry-point || exit 1; \
	done

# test runs the colocated unit tests.
#
# ODIN_TEST_THREADS=1 forces serial execution: bifrost's runtime is a set of
# global singletons (allp, sched, m0, g0, current_g), so tests that boot it
# cannot run concurrently against shared state. A per-test fresh runtime is
# planned for Phase 13.2; until then, serial is correct.
#
# Integration/stress tests early-return unless BIFROST_INTEGRATION=1 (see
# test-integration).
test:
	@for pkg in $(PACKAGES); do \
		echo "==> odin test $$pkg"; \
		odin test $$pkg -define:ODIN_TEST_THREADS=1 || exit 1; \
	done

# test-integration runs the heavier env-gated scheduler stress tests.
test-integration:
	@for pkg in $(PACKAGES); do \
		echo "==> odin test $$pkg (integration)"; \
		BIFROST_INTEGRATION=1 odin test $$pkg -define:ODIN_TEST_THREADS=1 || exit 1; \
	done

# examples compiles every example program into ./bin.
examples:
	@mkdir -p $(BIN)
	@for ex in $(EXAMPLES); do \
		echo "==> odin build examples/$$ex"; \
		odin build examples/$$ex -out=$(BIN)/$$ex || exit 1; \
	done

# run-example builds and runs a single example: make run-example EXAMPLE=hello
EXAMPLE ?= hello
run-example:
	@mkdir -p $(BIN)
	odin run examples/$(EXAMPLE) -out=$(BIN)/$(EXAMPLE)

clean:
	rm -rf $(BIN)
