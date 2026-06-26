DEPS := claude curl jq
PREFIX ?= $(HOME)/.local/bin

.PHONY: check lint test setup install hooks
check:
	@for t in $(DEPS); do \
		command -v $$t >/dev/null 2>&1 || { echo "missing required tool: $$t"; exit 1; }; \
	done; \
	echo "deps ok: $(DEPS)"

lint:
	shellcheck bin/claude-openrouter setup.sh lib/common.sh lib/check-openrouter.sh tests/smoke.sh .githooks/pre-commit

test:
	./tests/smoke.sh

setup:
	./setup.sh $(ARGS)

install:
	@mkdir -p "$(PREFIX)"
	@ln -sf "$(CURDIR)/bin/claude-openrouter" "$(PREFIX)/claude-openrouter"
	@echo "linked $(PREFIX)/claude-openrouter -> $(CURDIR)/bin/claude-openrouter"
	@case ":$$PATH:" in *":$(PREFIX):"*) ;; *) echo "note: add $(PREFIX) to your PATH";; esac

hooks:
	@git config core.hooksPath .githooks
	@echo "enabled .githooks (pre-commit runs gitleaks on staged changes)"
