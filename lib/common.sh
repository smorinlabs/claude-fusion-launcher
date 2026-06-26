#!/usr/bin/env bash
# lib/common.sh — shared helpers for claude-fusion-launcher.
# Source from setup.sh and bin/claude-fusion. Not meant to be executed directly.
# shellcheck shell=bash

CFL_ROOT="${CFL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFL_CONFIG_EXAMPLE="$CFL_ROOT/config/modes.json.example"
# Config resolution (no need to create modes.json — the shipped example IS the
# default): explicit $CLAUDE_FUSION_CONFIG > user's config/modes.json > example.
if [ -n "${CLAUDE_FUSION_CONFIG:-}" ]; then
  CFL_CONFIG="$CLAUDE_FUSION_CONFIG"
elif [ -f "$CFL_ROOT/config/modes.json" ]; then
  CFL_CONFIG="$CFL_ROOT/config/modes.json"
else
  CFL_CONFIG="$CFL_CONFIG_EXAMPLE"
fi
CFL_STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-fusion"
# shellcheck disable=SC2034  # OR_API is used by setup.sh (which sources this file)
OR_API="https://openrouter.ai/api/v1"

cfl_die() { echo "claude-fusion: $*" >&2; exit 1; }
cfl_warn() { echo "claude-fusion: $*" >&2; }

# cfl_require <tool>... — fail if any tool is missing from PATH.
cfl_require() {
  local t missing=""
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || cfl_die "missing required tools:$missing"
}

# cfl_resolve_key <key-arg> <key-file-arg>
# Precedence: --key > --key-file > $OPENROUTER_API_KEY. Prints the key to stdout.
# Never logs the key; reads key files WITHOUT sourcing them (no env pollution).
cfl_resolve_key() {
  local key="$1" keyfile="$2" k
  if [ -n "$key" ]; then printf '%s' "$key"; return 0; fi
  if [ -n "$keyfile" ]; then
    [ -f "$keyfile" ] || cfl_die "key file not found: $keyfile"
    k="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=//p' "$keyfile" \
          | head -1 | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
    [ -n "$k" ] || cfl_die "OPENROUTER_API_KEY not found in $keyfile"
    printf '%s' "$k"; return 0
  fi
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then printf '%s' "$OPENROUTER_API_KEY"; return 0; fi
  cfl_die "no OpenRouter key — use --key, --key-file FILE, or export OPENROUTER_API_KEY"
}

# cfl_load_config — ensure the resolved config exists and is valid JSON.
cfl_load_config() {
  [ -f "$CFL_CONFIG" ] || cfl_die "config not found: $CFL_CONFIG"
  jq -e . "$CFL_CONFIG" >/dev/null 2>&1 || cfl_die "invalid JSON in $CFL_CONFIG"
}

# cfl_cfg <jq-args...> — query the config (raw output). Forwards extra args
# (e.g. --arg) so callers can pass profile names safely.
cfl_cfg() { jq -r "$@" "$CFL_CONFIG"; }

# cfl_resolve_profile <cli_profile> — profile to use (cli arg > .default_profile).
cfl_resolve_profile() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  cfl_cfg '.default_profile // empty'
}

# cfl_resolve_mode <cli_mode> — mode to use (cli arg > .default_mode > "extreme").
cfl_resolve_mode() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  local m; m="$(cfl_cfg '.default_mode // empty')"
  if [ -n "$m" ]; then printf '%s' "$m"; else printf 'extreme'; fi
}

# cfl_profile_type <profile> — "fusion" | "model" | "" (unknown).
# shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
cfl_profile_type() { cfl_cfg --arg p "$1" '.profiles[$p].type // empty'; }

# cfl_preset_ready <slug> — true iff the per-slug readiness marker exists.
cfl_preset_ready() { [ -f "$CFL_STATE_DIR/presets/$1.json" ]; }

# cfl_preset_backed_profiles — names of all profiles that need an OpenRouter
# preset created (type "fusion" or "preset"), one per line.
cfl_preset_backed_profiles() {
  cfl_cfg '.profiles | to_entries[] | select(.value.type=="fusion" or .value.type=="preset") | .key'
}

# cfl_profile_backend_ref <profile> — resolve a NAMED profile to its backend
# string. fusion/preset -> @preset/<slug> when ready else fallback; model -> slug.
cfl_profile_backend_ref() {
  local p="$1" type
  type="$(cfl_profile_type "$p")"
  # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
  case "$type" in
    model) cfl_cfg --arg p "$p" '.profiles[$p].model // empty' ;;
    fusion)
      local slug fallback
      slug="$(cfl_cfg --arg p "$p" '.profiles[$p].preset_slug // empty')"
      fallback="$(cfl_cfg --arg p "$p" '.profiles[$p].fallback // "openrouter/fusion"')"
      if [ -n "$slug" ] && cfl_preset_ready "$slug"; then printf '@preset/%s' "$slug"; else printf '%s' "$fallback"; fi
      ;;
    preset)
      # A provider-pinned (or parameterized) preset; before setup it falls back to
      # its bare model (unpinned), so the profile still works without ./setup.sh.
      local slug fallback
      slug="$(cfl_cfg --arg p "$p" '.profiles[$p].preset_slug // empty')"
      fallback="$(cfl_cfg --arg p "$p" '.profiles[$p].fallback // .profiles[$p].model // empty')"
      if [ -n "$slug" ] && cfl_preset_ready "$slug"; then printf '@preset/%s' "$slug"; else printf '%s' "$fallback"; fi
      ;;
    *) cfl_die "unknown profile '$p' — available: $(cfl_cfg '.profiles | keys | join(", ")')" ;;
  esac
}

# cfl_backend_ref <profile> <direct_slug> — top-level backend resolution.
# A non-empty direct_slug (from --backend) wins and is used verbatim.
cfl_backend_ref() {
  local profile="${1:-}" direct="${2:-}"
  if [ -n "$direct" ]; then printf '%s' "$direct"; return 0; fi
  cfl_profile_backend_ref "$profile"
}

# cfl_list_profiles — print the profiles with their resolved targets.
cfl_list_profiles() {
  echo "Profiles (config: $CFL_CONFIG):"
  jq -r '.profiles | to_entries[]
    | if   .value.type=="fusion" then "  \(.key) (fusion): @preset/\(.value.preset_slug) — \(.value.panel_models|length)-model panel, judge \(.value.judge_model)"
      elif .value.type=="preset" then "  \(.key) (preset): @preset/\(.value.preset_slug) — \(.value.model) via provider \((.value.provider.only // .value.provider.order // []) | join(", "))"
      elif .value.type=="model"  then "  \(.key) (model): \(.value.model)"
      else "  \(.key) (unknown type)" end' "$CFL_CONFIG"
  printf '  default_profile: %s   default_mode: %s\n' "$(cfl_cfg '.default_profile // "—"')" "$(cfl_cfg '.default_mode // "extreme"')"
}

# cfl_render_settings <mode> <profile> [direct_slug] — build a Claude Code
# settings JSON for the mode against the resolved backend, and print its path.
# The literal "backend" in any slot resolves to cfl_backend_ref.
cfl_render_settings() {
  local mode="$1" profile="${2:-}" direct="${3:-}" fref out modeobj
  modeobj="$(jq -c --arg m "$mode" '.modes[$m] // empty' "$CFL_CONFIG")"
  [ -n "$modeobj" ] || cfl_die "unknown mode '$mode' — available: $(cfl_cfg '.modes | keys | join(", ")')"
  fref="$(cfl_backend_ref "$profile" "$direct")"
  mkdir -p "$CFL_STATE_DIR"
  out="$CFL_STATE_DIR/$mode.json"
  jq -n --arg fref "$fref" --argjson m "$modeobj" '
    def res(v): if v == "backend" then $fref else v end;
    {
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      model: res($m.default // "opus"),
      env: (
        {
          "ANTHROPIC_API_KEY": "",
          "ANTHROPIC_BASE_URL": "https://openrouter.ai/api",
          "CLAUDE_CODE_DISABLE_ADVISOR_TOOL": "1",
          "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
          "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
          "DISABLE_INTERLEAVED_THINKING": "1"
        }
        + (if $m.opus     != null then {"ANTHROPIC_DEFAULT_OPUS_MODEL":   res($m.opus)}     else {} end)
        + (if $m.sonnet   != null then {"ANTHROPIC_DEFAULT_SONNET_MODEL": res($m.sonnet)}   else {} end)
        + (if $m.haiku    != null then {"ANTHROPIC_DEFAULT_HAIKU_MODEL":  res($m.haiku)}    else {} end)
        + (if $m.subagent != null then {"CLAUDE_CODE_SUBAGENT_MODEL":     res($m.subagent)} else {} end)
      )
    }' > "$out"
  printf '%s' "$out"
}

# cfl_or_get <key> <path-after-/api/v1> — GET an OpenRouter API endpoint.
# Prints the JSON body; returns non-zero on HTTP/transport error. Bounded by a
# timeout so a stalled network can't hang doctor / setup / the --cost poll.
cfl_or_get() { curl -fsS --connect-timeout 5 --max-time 15 "$OR_API/$2" -H "Authorization: Bearer $1"; }

# cfl_credits_usage <key> — print cumulative account usage ($) as a number.
cfl_credits_usage() { cfl_or_get "$1" "credits" | jq -r '.data.total_usage // empty'; }

# cfl_preset_check <key> <slug> — pre-flight preset existence check. Distinguishes
# a missing preset (HTTP error) from a transient network failure so the launcher
# only hard-aborts on the former. Returns:
#   0 = preset exists (HTTP 2xx)
#   1 = HTTP error (e.g. 404) — preset not available on this account
#   2 = transport/network error (no HTTP response) — existence unknown
cfl_preset_check() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 \
    "$OR_API/presets/$2" -H "Authorization: Bearer $1" 2>/dev/null)" || true
  case "$code" in
    2*)      return 0 ;;
    ''|000)  return 2 ;;
    *)       return 1 ;;
  esac
}

# cfl_provider_match <live_provider_json> <cfg_provider_json> — true iff every key
# the config sets on the provider object equals the same key in the live preset.
# Extra/reordered fields OpenRouter may add are ignored, so they don't read as drift.
cfl_provider_match() {
  jq -ne --argjson live "$1" --argjson cfg "$2" \
    '[$cfg | to_entries[] | $live[.key] == .value] | all' >/dev/null 2>&1
}

# cfl_list_modes — print the modes from config with their slot mappings.
cfl_list_modes() {
  echo "Modes (config: $CFL_CONFIG):"
  jq -r '.modes | to_entries[]
    | "  \(.key): default=\(.value.default) opus=\(.value.opus) sonnet=\(.value.sonnet) haiku=\(.value.haiku) subagent=\(.value.subagent)"' "$CFL_CONFIG"
  echo "  ('backend' resolves to the active profile's target — see 'claude-fusion profiles')"
}

# cfl_doctor <key> — health checks with ✓/✗/⚠ and fix hints. Returns non-zero on ✗.
cfl_doctor() {
  local key="$1" src="${2:-}" rc=0
  _d_ok()   { printf '  \xe2\x9c\x93 %s\n' "$1"; }
  _d_no()   { printf '  \xe2\x9c\x97 %s\n' "$1"; [ -n "${2:-}" ] && printf '      \xe2\x86\xb3 %s\n' "$2"; rc=1; }
  _d_warn() { printf '  \xe2\x9a\xa0 %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      \xe2\x86\xb3 %s\n' "$2"; fi; }
  _d_det()  { printf '      %s\n' "$1"; }

  echo "claude-fusion doctor"
  echo "--- environment ---"
  local t
  for t in claude curl jq; do
    if command -v "$t" >/dev/null 2>&1; then _d_ok "$t ($("$t" --version 2>/dev/null | head -1))"; else _d_no "$t missing" "install $t"; fi
  done

  echo "--- config ---"
  if [ -f "$CFL_CONFIG" ] && jq -e . "$CFL_CONFIG" >/dev/null 2>&1; then
    _d_ok "config: $CFL_CONFIG (modes: $(jq -r '.modes|keys|join(", ")' "$CFL_CONFIG"))"
  else
    _d_no "config invalid or missing: $CFL_CONFIG" "fix the JSON or copy config/modes.json.example"
  fi
  if [ -f "$CFL_CONFIG" ] && jq -e . "$CFL_CONFIG" >/dev/null 2>&1; then
    while IFS= read -r line; do _d_det "$line"; done < <(cfl_list_profiles)
  fi

  echo "--- key & account ---"
  if [ -z "$key" ]; then
    _d_warn "no key provided — skipping key/credit/preset checks" "pass --key/--key-file or set OPENROUTER_API_KEY"
  else
    # Confirm which key was resolved (local last-4) and where it came from, so a
    # wrong key file / env var is obvious before any account call.
    case "$src" in
      file:*) _d_ok "key resolved (…${key: -4}) — source: file ${src#file:}" ;;
      env:*)  _d_ok "key resolved (…${key: -4}) — source: env \$${src#env:}" ;;
      flag)   _d_ok "key resolved (…${key: -4}) — source: --key flag" ;;
      *)      _d_ok "key resolved (…${key: -4})" ;;
    esac
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
      _d_warn "curl/jq needed for account checks"
    else
      local kinfo
      if kinfo="$(cfl_or_get "$key" "key" 2>/dev/null)"; then
        _d_ok "key valid (label $(printf '%s' "$kinfo" | jq -r '.data.label // "?"'))"
        local cred rem use
        if cred="$(cfl_or_get "$key" "credits" 2>/dev/null)"; then
          rem="$(printf '%s' "$cred" | jq -r '((.data.total_credits // 0) - (.data.total_usage // 0)) | (.*100|round)/100')"
          use="$(printf '%s' "$cred" | jq -r '(.data.total_usage // 0) | (.*100|round)/100')"
          if printf '%s' "$cred" | jq -e '((.data.total_credits // 0) - (.data.total_usage // 0)) > 1' >/dev/null; then
            _d_ok "credits: \$$rem remaining (used \$$use)"
          else
            _d_warn "low credits: \$$rem remaining" "add credits at https://openrouter.ai/settings/credits"
          fi
        fi
        local prof ptype slug pinfo pm pt
        while IFS= read -r prof; do
          [ -n "$prof" ] || continue
          ptype="$(cfl_profile_type "$prof")"
          # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
          slug="$(cfl_cfg --arg p "$prof" '.profiles[$p].preset_slug // empty')"
          [ -n "$slug" ] || { _d_warn "profile '$prof' (type $ptype) has no preset_slug in config" "add a preset_slug to the profile"; continue; }
          if pinfo="$(cfl_or_get "$key" "presets/$slug" 2>/dev/null)"; then
            pm="$(printf '%s' "$pinfo" | jq -r '.data.designated_version.config.model // empty')"
            if [ "$ptype" = "fusion" ]; then
              pt="$(printf '%s' "$pinfo" | jq -r '[.data.designated_version.config.tools[]?.type] | index("openrouter:fusion") // empty')"
              if [ "$pm" = "openrouter/fusion" ] && [ -n "$pt" ]; then
                _d_ok "preset '$slug' configured (profile '$prof', custom panel)"
                cfl_preset_ready "$slug" || _d_warn "PRESET_READY marker missing or stale for '$slug'" "run ./setup.sh to write it"
                local live_panel live_judge live_tc cfg_panel cfg_judge
                live_panel="$(printf '%s' "$pinfo" | jq -r '[.data.designated_version.config.tools[]? | select(.type=="openrouter:fusion").parameters.analysis_models[]?] | join(", ")')"
                live_judge="$(printf '%s' "$pinfo" | jq -r '[.data.designated_version.config.tools[]? | select(.type=="openrouter:fusion").parameters.model][0] // "?"')"
                live_tc="$(printf '%s' "$pinfo" | jq -r '.data.designated_version.config.tool_choice // "?"')"
                _d_det "panel: $live_panel"
                _d_det "judge: $live_judge"
                _d_det "tool_choice: $live_tc"
                # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
                cfg_panel="$(cfl_cfg --arg p "$prof" '.profiles[$p].panel_models | join(", ")')"
                # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
                cfg_judge="$(cfl_cfg --arg p "$prof" '.profiles[$p].judge_model')"
                if [ "$live_panel" = "$cfg_panel" ] && [ "$live_judge" = "$cfg_judge" ]; then
                  _d_ok "preset '$slug' matches config (panel + judge in sync)"
                else
                  _d_warn "preset '$slug' differs from config — re-run ./setup.sh to sync"
                  if [ "$live_panel" != "$cfg_panel" ]; then
                    _d_det "panel (config): $cfg_panel"
                    _d_det "panel (live):   $live_panel"
                  fi
                  if [ "$live_judge" != "$cfg_judge" ]; then
                    _d_det "judge (config): $cfg_judge"
                    _d_det "judge (live):   $live_judge"
                  fi
                fi
              else
                _d_no "preset '$slug' exists but misconfigured (model=$pm)" "re-run ./setup.sh"
              fi
            else
              # type "preset": a provider-pinned/parameterized single model.
              local cfg_model live_prov cfg_prov
              # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
              cfg_model="$(cfl_cfg --arg p "$prof" '.profiles[$p].model')"
              if [ "$pm" = "$cfg_model" ]; then
                _d_ok "preset '$slug' configured (profile '$prof', model $pm)"
                cfl_preset_ready "$slug" || _d_warn "PRESET_READY marker missing or stale for '$slug'" "run ./setup.sh to write it"
                live_prov="$(printf '%s' "$pinfo" | jq -c '.data.designated_version.config.provider // {}')"
                # shellcheck disable=SC2016  # $p is a jq variable, not a bash expansion
                cfg_prov="$(jq -c --arg p "$prof" '.profiles[$p].provider // {}' "$CFL_CONFIG")"
                _d_det "model: $pm"
                _d_det "provider: $live_prov"
                if cfl_provider_match "$live_prov" "$cfg_prov"; then
                  _d_ok "preset '$slug' matches config (model + provider in sync)"
                else
                  _d_warn "preset '$slug' differs from config — re-run ./setup.sh to sync"
                  _d_det "provider (config): $cfg_prov"
                  _d_det "provider (live):   $live_prov"
                fi
              else
                _d_no "preset '$slug' exists but model mismatch (model=$pm, expected $cfg_model)" "re-run ./setup.sh"
              fi
            fi
          else
            _d_warn "preset '$slug' (profile '$prof') not found for this key" "run ./setup.sh (launcher uses the profile's fallback until then)"
          fi
        done < <(cfl_preset_backed_profiles)
      else
        _d_no "OpenRouter rejected the key (GET /api/v1/key failed)" "check the key is valid and not expired"
      fi
    fi
  fi

  echo "--- claude code env ---"
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    _d_warn "ANTHROPIC_API_KEY is set in your shell" "the launcher unsets it per-run, but it can break other claude usage; consider unsetting"
  else
    _d_ok "ANTHROPIC_API_KEY not set in shell"
  fi

  echo
  if [ "$rc" -eq 0 ]; then echo "doctor: all critical checks passed"; else echo "doctor: problems found (see the failing lines above)"; fi
  return "$rc"
}
