#!/usr/bin/env bash
# setup.sh — creates an OpenRouter preset for each fusion profile in the config.
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
only_profile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key) key="${2:?--key needs a value}"; shift 2;;
    --key=*) key="${1#*=}"; shift;;
    --key-file) keyfile="${2:?--key-file needs a value}"; shift 2;;
    --key-file=*) keyfile="${1#*=}"; shift;;
    --profile) only_profile="${2:?--profile needs a value}"; shift 2;;
    --profile=*) only_profile="${1#*=}"; shift;;
    -h|--help) echo "Usage: ./setup.sh [--profile NAME] [--key KEY | --key-file FILE]"; exit 0;;
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

# Decide which preset-backed profiles to create (type "fusion" or "preset").
profiles_to_do=()
if [ -n "$only_profile" ]; then
  ptype="$(cfl_profile_type "$only_profile")"
  [ -n "$ptype" ] || cfl_die "unknown profile '$only_profile' — available: $(cfl_cfg '.profiles | keys | join(", ")')"
  if [ "$ptype" != "fusion" ] && [ "$ptype" != "preset" ]; then
    echo "setup: profile '$only_profile' is type '$ptype' — nothing to set up (only fusion/preset profiles need a preset)."
    exit 0
  fi
  profiles_to_do=("$only_profile")
else
  while IFS= read -r p; do [ -n "$p" ] && profiles_to_do+=("$p"); done < <(cfl_preset_backed_profiles)
  [ "${#profiles_to_do[@]}" -gt 0 ] || cfl_die "no fusion/preset profiles in config — nothing to set up"
fi

mkdir -p "$CFL_STATE_DIR/presets"
overall_fail=0
for prof in "${profiles_to_do[@]}"; do
  ptype="$(cfl_profile_type "$prof")"
  # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
  slug="$(cfl_cfg --arg p "$prof" '.profiles[$p].preset_slug')"

  if [ "$ptype" = "fusion" ]; then
    # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
    judge="$(cfl_cfg --arg p "$prof" '.profiles[$p].judge_model')"
    panel="$(jq -c --arg p "$prof" '.profiles[$p].panel_models' "$CFL_CONFIG")"
    echo "setup: creating OpenRouter preset '$slug' (profile '$prof', fusion)"
    echo "       panel: $(echo "$panel" | jq -r 'join(", ")')"
    echo "       judge: $judge"
    body="$(jq -n --argjson panel "$panel" --arg judge "$judge" '{
      model: "openrouter/fusion",
      tools: [{ type: "openrouter:fusion", parameters: { analysis_models: $panel, model: $judge } }],
      tool_choice: "required",
      messages: [{ role: "user", content: "(ignored on preset create)" }]
    }')"
    expect_model="openrouter/fusion"
  else
    # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
    model="$(cfl_cfg --arg p "$prof" '.profiles[$p].model')"
    provider="$(jq -c --arg p "$prof" '.profiles[$p].provider // {}' "$CFL_CONFIG")"
    echo "setup: creating OpenRouter preset '$slug' (profile '$prof', preset)"
    echo "       model: $model"
    echo "       provider: $provider"
    body="$(jq -n --arg model "$model" --argjson provider "$provider" '{
      model: $model,
      provider: $provider,
      messages: [{ role: "user", content: "(ignored on preset create)" }]
    }')"
    expect_model="$model"
  fi

  resp="$(curl -sS "$OR_API/presets/$slug/chat/completions" \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    -d "$body")"

  got_model="$(echo "$resp" | jq -r '.data.designated_version.config.model // empty' 2>/dev/null || true)"
  ok=0
  if [ "$ptype" = "fusion" ]; then
    has_tool="$(echo "$resp" | jq -r '[.data.designated_version.config.tools[]?.type] | index("openrouter:fusion") // empty' 2>/dev/null || true)"
    [ "$got_model" = "$expect_model" ] && [ -n "$has_tool" ] && ok=1
  else
    [ "$got_model" = "$expect_model" ] && ok=1
  fi

  if [ "$ok" = "1" ]; then
    jq -n --arg preset_slug "$slug" --arg verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{preset_slug: $preset_slug, verified_at: $verified_at}' > "$CFL_STATE_DIR/presets/$slug.json"
    echo "setup: OK — preset '$slug' created (model=$got_model)."
  else
    err="$(echo "$resp" | jq -r '.error.message // "unknown error (see response below)"' 2>/dev/null || echo "unknown error (see response below)")"
    hint=""
    case "$err" in
      *redit*|*nsufficient*)                        hint="add credits at https://openrouter.ai/settings/credits";;
      *nvalid*key*|*uthenticat*|*nauthor*|*xpired*) hint="the OpenRouter key looks invalid or expired";;
      *not*found*|*o\ endpoints*|*o\ allowed*|*model*) hint="a panel model slug may be wrong — check config against https://openrouter.ai/api/v1/models";;
    esac
    echo "$resp" | jq . >&2 2>/dev/null || echo "$resp" >&2
    [ -n "$hint" ] && cfl_warn "hint: $hint"
    cfl_warn "preset creation failed for '$slug': $err"
    overall_fail=1
  fi
done

if [ "$overall_fail" -ne 0 ]; then
  cfl_die "preset creation failed (see messages above)"
fi

echo ""
echo "Next:"
echo "  bin/claude-fusion profiles                 # list profiles"
echo "  bin/claude-fusion --profile fusion         # fusion backend, default mode (extreme)"
echo "  bin/claude-fusion --profile fusion --mode subagent   # fusion only in subagents"
echo "  bin/claude-fusion --profile deepseek -p \"...\"        # a model-alias profile (no setup needed)"
