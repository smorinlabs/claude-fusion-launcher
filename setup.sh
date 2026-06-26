#!/usr/bin/env bash
# setup.sh — creates an OpenRouter preset for each fusion or preset profile in the config.
set -euo pipefail

# Resolve $0 through symlinks so setup works no matter where it's invoked from.
_src="$0"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
COL_ROOT="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck source=lib/common.sh
. "$COL_ROOT/lib/common.sh"

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
    *) col_die "unknown argument: $1";;
  esac
done

col_require curl jq

# Defaults ship in config/modes.json.example and are used automatically. To
# customize, copy it to config/modes.json and edit; that override wins here too.
col_load_config
echo "setup: using config $COL_CONFIG"

key="$(col_resolve_key "$key" "$keyfile")"

# Validate the key up front (clear failure instead of a cryptic preset error).
if kinfo="$(col_or_get "$key" "key" 2>/dev/null)"; then
  echo "setup: key OK (label $(printf '%s' "$kinfo" | jq -r '.data.label // "?"'))"
  if cred="$(col_or_get "$key" "credits" 2>/dev/null)"; then
    echo "setup: credits \$$(printf '%s' "$cred" | jq -r '((.data.total_credits//0)-(.data.total_usage//0))|(.*100|round)/100') remaining"
  fi
else
  col_die "OpenRouter rejected the key — check it is valid and not expired (via --key / --key-file / OPENROUTER_API_KEY)"
fi

# Decide which preset-backed profiles to create (type "fusion" or "preset").
profiles_to_do=()
if [ -n "$only_profile" ]; then
  ptype="$(col_profile_type "$only_profile")"
  [ -n "$ptype" ] || col_die "unknown profile '$only_profile' — available: $(col_cfg '.profiles | keys | join(", ")')"
  if [ "$ptype" != "fusion" ] && [ "$ptype" != "preset" ]; then
    echo "setup: profile '$only_profile' is type '$ptype' — nothing to set up (only fusion/preset profiles need a preset)."
    exit 0
  fi
  profiles_to_do=("$only_profile")
else
  while IFS= read -r p; do [ -n "$p" ] && profiles_to_do+=("$p"); done < <(col_preset_backed_profiles)
  [ "${#profiles_to_do[@]}" -gt 0 ] || col_die "no fusion/preset profiles in config — nothing to set up"
fi

mkdir -p "$COL_STATE_DIR/presets"
overall_fail=0
for prof in "${profiles_to_do[@]}"; do
  ptype="$(col_profile_type "$prof")"
  # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
  slug="$(col_cfg --arg p "$prof" '.profiles[$p].preset_slug // empty')"
  if [ -z "$slug" ]; then
    col_warn "profile '$prof' (type $ptype) is missing preset_slug — skipping"
    overall_fail=1
    continue
  fi
  # Clear any stale readiness marker before we (re)try, so a failed attempt never
  # leaves a preset looking ready — backend resolution only checks marker existence.
  rm -f "$COL_STATE_DIR/presets/$slug.json"

  if [ "$ptype" = "fusion" ]; then
    # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
    judge="$(col_cfg --arg p "$prof" '.profiles[$p].judge_model')"
    panel="$(jq -c --arg p "$prof" '.profiles[$p].panel_models' "$COL_CONFIG")"
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
    model="$(col_cfg --arg p "$prof" '.profiles[$p].model // empty')"
    if [ -z "$model" ]; then
      col_warn "preset profile '$prof' is missing model — skipping"
      overall_fail=1
      continue
    fi
    provider="$(jq -c --arg p "$prof" '.profiles[$p].provider // {}' "$COL_CONFIG")"
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
    # Verify the persisted preset matches config on the same fields doctor diffs
    # (panel + judge + tool_choice), so a silently-rewritten preset isn't marked ready.
    has_tool="$(echo "$resp" | jq -r '[.data.designated_version.config.tools[]?.type] | index("openrouter:fusion") // empty' 2>/dev/null || true)"
    live_panel="$(echo "$resp" | jq -r '[.data.designated_version.config.tools[]? | select(.type=="openrouter:fusion").parameters.analysis_models[]?] | join(", ")' 2>/dev/null || true)"
    live_judge="$(echo "$resp" | jq -r '[.data.designated_version.config.tools[]? | select(.type=="openrouter:fusion").parameters.model][0] // empty' 2>/dev/null || true)"
    live_tc="$(echo "$resp" | jq -r '.data.designated_version.config.tool_choice // empty' 2>/dev/null || true)"
    cfg_panel="$(echo "$panel" | jq -r 'join(", ")')"
    if [ "$got_model" = "$expect_model" ] && [ -n "$has_tool" ] \
       && [ "$live_panel" = "$cfg_panel" ] && [ "$live_judge" = "$judge" ] && [ "$live_tc" = "required" ]; then
      ok=1
    fi
  else
    # Confirm the provider pin actually persisted, not just the model — otherwise a
    # silently-dropped provider would look like success but route unpinned.
    got_prov="$(echo "$resp" | jq -c '.data.designated_version.config.provider // {}' 2>/dev/null || echo '{}')"
    if [ "$got_model" = "$expect_model" ] && col_provider_match "$got_prov" "$provider"; then ok=1; fi
  fi

  if [ "$ok" = "1" ]; then
    jq -n --arg preset_slug "$slug" --arg verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{preset_slug: $preset_slug, verified_at: $verified_at}' > "$COL_STATE_DIR/presets/$slug.json"
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
    [ -n "$hint" ] && col_warn "hint: $hint"
    col_warn "preset creation failed for '$slug': $err"
    overall_fail=1
  fi
done

if [ "$overall_fail" -ne 0 ]; then
  col_die "preset creation failed (see messages above)"
fi

echo ""
echo "Next:"
echo "  bin/claude-openrouter profiles                 # list profiles"
for _prof in "${profiles_to_do[@]}"; do
  echo "  bin/claude-openrouter --profile $_prof         # use the profile just set up"
done
echo "  bin/claude-openrouter --profile <model-alias> -p \"...\"   # model aliases (e.g. deepseek) need no setup"
