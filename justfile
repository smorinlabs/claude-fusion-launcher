set positional-arguments

# list recipes
default:
    @just --list

# verify required tools (claude, curl, jq)
check:
    @make check

# shellcheck all scripts
lint:
    shellcheck bin/claude-fusion setup.sh lib/common.sh tests/smoke.sh

# run no-cost smoke tests
test:
    ./tests/smoke.sh

# one-time: create your OpenRouter cc-fusion preset (pass --key/--key-file as needed)
setup *args:
    ./setup.sh {{args}}

# run Claude Code with a fusion mode (default: subagent). e.g. `just run main -p "hi"`
run mode="subagent" *args:
    bin/claude-fusion --mode {{mode}} {{args}}
