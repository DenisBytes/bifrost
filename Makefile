PACKAGES = bifrost

EXAMPLES = hello spawn pingpong parallel chan

BIN = bin

# OPT is the Odin optimization level threaded through every build and test
# target. It is empty (Odin's implicit -o:minimal) by default and is set by the
# *-speed / *-size targets below.
#
# This matters more than it looks. bifrost's context switch preserves
# callee-saved registers across an OS-thread change, so the runtime is sensitive
# to what the optimizer is allowed to cache in one — a green suite at the
# default level is NOT evidence that a release build works. That is exactly how
# the TLS thread-pointer defect stayed invisible behind a fully green main:
# nothing in this Makefile or in CI had ever passed an -o: flag. Every gate now
# runs at both.
OPT ?=

TEST_FLAGS = -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

.PHONY: build check check-examples test test-integration test-speed test-size \
        examples examples-speed run-example clean

# build type-checks the library and compiles every example into ./bin.
build: check examples

# check runs Odin's type checker with vet and strict-style over the library AND
# every example. -vet-tabs is what actually enforces tab indentation;
# -strict-style alone covers brace placement and stray tokens but not indentation.
# The examples are included because they are the project's front door and were
# previously ungated (examples/pingpong failed this very check).
check:
	@for pkg in $(PACKAGES); do \
		echo "==> odin check $$pkg"; \
		odin check $$pkg -vet -vet-tabs -strict-style -no-entry-point || exit 1; \
	done
	@$(MAKE) --no-print-directory check-examples

check-examples:
	@for ex in $(EXAMPLES); do \
		echo "==> odin check examples/$$ex"; \
		odin check examples/$$ex -vet -vet-tabs -strict-style || exit 1; \
	done

# test runs the colocated unit tests.
#
# ODIN_TEST_THREADS=1 forces serial execution: bifrost's runtime is a set of
# global singletons (allp, sched, m0, g0, tls_g), so tests that boot it cannot
# run concurrently against shared state. A per-test fresh runtime is planned for
# Phase 13.2; until then, serial is correct.
#
# ODIN_TEST_FAIL_ON_BAD_MEMORY makes a leak or a bad free fail the suite rather
# than merely printing to the log.
#
# Integration/stress tests early-return unless BIFROST_INTEGRATION=1 (see
# test-integration).
test:
	@for pkg in $(PACKAGES); do \
		echo "==> odin test $$pkg $(OPT)"; \
		odin test $$pkg $(TEST_FLAGS) $(OPT) || exit 1; \
	done

# test-integration runs the heavier env-gated scheduler stress tests.
test-integration:
	@for pkg in $(PACKAGES); do \
		echo "==> odin test $$pkg (integration) $(OPT)"; \
		BIFROST_INTEGRATION=1 odin test $$pkg $(TEST_FLAGS) $(OPT) || exit 1; \
	done

# test-speed / test-size are merge gates, not extras. See OPT above.
test-speed:
	@$(MAKE) --no-print-directory test OPT=-o:speed
	@$(MAKE) --no-print-directory test-integration OPT=-o:speed

test-size:
	@$(MAKE) --no-print-directory test OPT=-o:size
	@$(MAKE) --no-print-directory test-integration OPT=-o:size

# examples compiles every example program into ./bin.
examples:
	@mkdir -p $(BIN)
	@for ex in $(EXAMPLES); do \
		echo "==> odin build examples/$$ex $(OPT)"; \
		odin build examples/$$ex -out=$(BIN)/$$ex $(OPT) || exit 1; \
	done

# examples-speed builds AND RUNS every example optimized. Building alone is not
# enough: the TLS defect produced binaries that linked cleanly and segfaulted on
# the first multi-threaded workload.
examples-speed:
	@$(MAKE) --no-print-directory examples OPT=-o:speed
	@for ex in $(EXAMPLES); do \
		echo "==> run $(BIN)/$$ex (-o:speed)"; \
		timeout 60 ./$(BIN)/$$ex > /dev/null || { echo "FAILED: $$ex"; exit 1; }; \
	done

# run-example builds and runs a single example: make run-example EXAMPLE=hello
EXAMPLE ?= hello
run-example:
	@mkdir -p $(BIN)
	odin run examples/$(EXAMPLE) -out=$(BIN)/$(EXAMPLE) $(OPT)

clean:
	rm -rf $(BIN)
