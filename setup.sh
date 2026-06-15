#!/usr/bin/env bash
# setup.sh — one-time per-user setup: create your OpenRouter "cc-fusion" preset.
set -euo pipefail

# Resolve $0 through symlinks so setup works no matter where it's invoked from.
_src="$0"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
CFL_ROOT="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck source=lib/common.sh
. "$CFL_ROOT/lib/common.sh"

key=""
keyfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key) key="${2:?--key needs a value}"; shift 2;;
    --key=*) key="${1#*=}"; shift;;
    --key-file) keyfile="${2:?--key-file needs a value}"; shift 2;;
    --key-file=*) keyfile="${1#*=}"; shift;;
    -h|--help) echo "Usage: ./setup.sh [--key KEY | --key-file FILE]"; exit 0;;
    *) cfl_die "unknown argument: $1";;
  esac
done

cfl_require claude curl jq

# Defaults ship in config/modes.json.example and are used automatically. To
# customize, copy it to config/modes.json and edit; that override wins here too.
cfl_load_config
echo "setup: using config $CFL_CONFIG"

key="$(cfl_resolve_key "$key" "$keyfile")"
slug="$(cfl_cfg '.preset_slug')"
judge="$(cfl_cfg '.judge_model')"
panel="$(jq -c '.panel_models' "$CFL_CONFIG")"

echo "setup: creating OpenRouter preset '$slug'"
echo "       panel: $(echo "$panel" | jq -r 'join(", ")')"
echo "       judge: $judge"

# A preset only activates fusion when its model is "openrouter/fusion" + a fusion
# tools block; tool_choice:required drives the full custom-panel deliberation.
body="$(jq -n --argjson panel "$panel" --arg judge "$judge" '{
  model: "openrouter/fusion",
  tools: [{ type: "openrouter:fusion", parameters: { analysis_models: $panel, model: $judge } }],
  tool_choice: "required",
  messages: [{ role: "user", content: "(ignored on preset create)" }]
}')"

resp="$(curl -sS "$OR_API/presets/$slug/chat/completions" \
  -H "Authorization: Bearer $key" \
  -H "Content-Type: application/json" \
  -d "$body")"

got_model="$(echo "$resp" | jq -r '.data.designated_version.config.model // empty')"
has_tool="$(echo "$resp" | jq -r '[.data.designated_version.config.tools[]?.type] | index("openrouter:fusion") // empty')"

if [ "$got_model" = "openrouter/fusion" ] && [ -n "$has_tool" ]; then
  mkdir -p "$CFL_STATE_DIR"
  echo "preset '$slug' verified at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CFL_PRESET_READY"
  echo "setup: OK — preset '$slug' created (model=$got_model, fusion tool persisted)."
  echo ""
  echo "Next:"
  echo "  bin/claude-fusion --mode subagent     # Opus main, fusion subagents (cheapest)"
  echo "  bin/claude-fusion --mode main         # fusion main + subagents"
  echo "  bin/claude-fusion --mode extreme      # everything fusion"
  echo "  bin/claude-fusion --mode subagent -p \"...\"   # headless"
else
  err="$(echo "$resp" | jq -r '.error.message // "unknown error (see response below)"')"
  echo "$resp" | jq . >&2 2>/dev/null || echo "$resp" >&2
  cfl_die "preset creation failed: $err"
fi
