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

cfl_require curl jq

# Defaults ship in config/modes.json.example and are used automatically. To
# customize, copy it to config/modes.json and edit; that override wins here too.
cfl_load_config
echo "setup: using config $CFL_CONFIG"

key="$(cfl_resolve_key "$key" "$keyfile")"

# Validate the key up front (clear failure instead of a cryptic preset error).
if kinfo="$(cfl_or_get "$key" "key" 2>/dev/null)"; then
  echo "setup: key OK (label $(printf '%s' "$kinfo" | jq -r '.data.label // "?"'))"
  if cred="$(cfl_or_get "$key" "credits" 2>/dev/null)"; then
    echo "setup: credits \$$(printf '%s' "$cred" | jq -r '((.data.total_credits//0)-(.data.total_usage//0))|(.*100|round)/100') remaining"
  fi
else
  cfl_die "OpenRouter rejected the key — check it is valid and not expired (via --key / --key-file / OPENROUTER_API_KEY)"
fi

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

got_model="$(echo "$resp" | jq -r '.data.designated_version.config.model // empty' 2>/dev/null || true)"
has_tool="$(echo "$resp" | jq -r '[.data.designated_version.config.tools[]?.type] | index("openrouter:fusion") // empty' 2>/dev/null || true)"

if [ "$got_model" = "openrouter/fusion" ] && [ -n "$has_tool" ]; then
  mkdir -p "$CFL_STATE_DIR"
  jq -n --arg preset_slug "$slug" --arg verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{preset_slug: $preset_slug, verified_at: $verified_at}' > "$CFL_PRESET_READY"
  echo "setup: OK — preset '$slug' created (model=$got_model, fusion tool persisted)."
  echo ""
  echo "Next:"
  echo "  bin/claude-fusion --mode subagent     # Opus main, fusion subagents (cheapest)"
  echo "  bin/claude-fusion --mode main         # fusion main + subagents"
  echo "  bin/claude-fusion --mode extreme      # everything fusion"
  echo "  bin/claude-fusion --mode subagent -p \"...\"   # headless"
else
  err="$(echo "$resp" | jq -r '.error.message // "unknown error (see response below)"' 2>/dev/null || echo "unknown error (see response below)")"
  hint=""
  case "$err" in
    *redit*|*nsufficient*)                       hint="add credits at https://openrouter.ai/settings/credits";;
    *nvalid*key*|*uthenticat*|*nauthor*|*xpired*) hint="the OpenRouter key looks invalid or expired";;
    *not*found*|*o\ endpoints*|*o\ allowed*|*model*) hint="a panel model slug may be wrong — check config/modes.json against https://openrouter.ai/api/v1/models";;
  esac
  echo "$resp" | jq . >&2 2>/dev/null || echo "$resp" >&2
  [ -n "$hint" ] && cfl_warn "hint: $hint"
  cfl_die "preset creation failed: $err"
fi
