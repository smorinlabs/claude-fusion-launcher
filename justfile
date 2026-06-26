set positional-arguments := true

default_prefix := env_var("HOME") / ".local/bin"

# list recipes
default:
    @just --list

# verify required tools (claude, curl, jq)
check:
    @make check

# shellcheck all scripts
lint:
    shellcheck bin/claude-openrouter setup.sh lib/common.sh lib/check-openrouter.sh tests/smoke.sh .githooks/pre-commit

# run no-cost smoke tests
test:
    ./tests/smoke.sh

# run the full local verification suite
all: lint test

# one-time: create your OpenRouter cc-fusion preset (pass --key/--key-file as needed)
setup *args:
    ./setup.sh "$@"

# run Claude Code with a mode (default: extreme). e.g. `just run main -p "hi"`
run mode="extreme" *args:
    mode="$1"; shift; bin/claude-openrouter --mode "$mode" "$@"

# list available modes
modes:
    bin/claude-openrouter modes

# health checks (deps, key, credits, preset). pass --key-file as needed.
doctor *args:
    bin/claude-openrouter doctor "$@"

# symlink the launcher onto PATH (prefix defaults to ~/.local/bin)
install prefix=default_prefix:
    mkdir -p "{{ prefix }}"
    ln -sf "$(pwd)/bin/claude-openrouter" "{{ prefix }}/claude-openrouter"
    @echo "linked {{ prefix }}/claude-openrouter"

# enable the gitleaks pre-commit hook for this repo
hooks:
    git config core.hooksPath .githooks
    @echo "enabled .githooks (pre-commit runs gitleaks on staged changes)"
