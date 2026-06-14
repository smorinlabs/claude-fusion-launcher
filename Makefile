DEPS := claude curl jq

.PHONY: check lint test setup
check:
	@for t in $(DEPS); do \
		command -v $$t >/dev/null 2>&1 || { echo "missing required tool: $$t"; exit 1; }; \
	done; \
	echo "deps ok: $(DEPS)"

lint:
	shellcheck bin/claude-fusion setup.sh lib/common.sh tests/smoke.sh

test:
	./tests/smoke.sh

setup:
	./setup.sh
