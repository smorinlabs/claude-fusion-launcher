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
CFL_PRESET_READY="$CFL_STATE_DIR/PRESET_READY"
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

# cfl_cfg <jq-filter> — query the config (raw output).
cfl_cfg() { jq -r "$1" "$CFL_CONFIG"; }

# cfl_fusion_ref — the model string the "fusion" keyword resolves to:
# @preset/<slug> once setup has run, otherwise the configured fallback.
cfl_preset_marker_slug() {
  [ -f "$CFL_PRESET_READY" ] || return 1
  local slug
  slug="$(jq -r '.preset_slug // empty' "$CFL_PRESET_READY" 2>/dev/null || true)"
  if [ -z "$slug" ]; then
    slug="$(sed -nE "s/^preset '([^']+)'.*/\1/p; s/^preset_slug=(.*)$/\1/p" "$CFL_PRESET_READY" | head -1)"
  fi
  [ -n "$slug" ] || return 1
  printf '%s' "$slug"
}

cfl_preset_ready() {
  local slug marker_slug
  slug="$(cfl_cfg '.preset_slug')"
  marker_slug="$(cfl_preset_marker_slug || true)"
  [ "$marker_slug" = "$slug" ]
}

cfl_fusion_ref() {
  local slug fallback
  slug="$(cfl_cfg '.preset_slug')"
  fallback="$(cfl_cfg '.fallback // "openrouter/fusion"')"
  if cfl_preset_ready; then printf '@preset/%s' "$slug"; else printf '%s' "$fallback"; fi
}

# cfl_render_settings <mode> — build a Claude Code settings JSON for the mode and
# print the path to it. The literal "fusion" in any slot resolves to cfl_fusion_ref.
cfl_render_settings() {
  local mode="$1" fref out modeobj
  modeobj="$(jq -c --arg m "$mode" '.modes[$m] // empty' "$CFL_CONFIG")"
  [ -n "$modeobj" ] || cfl_die "unknown mode '$mode' — available: $(cfl_cfg '.modes | keys | join(", ")')"
  fref="$(cfl_fusion_ref)"
  mkdir -p "$CFL_STATE_DIR"
  out="$CFL_STATE_DIR/$mode.json"
  # Only emit env keys for slots the mode actually defines (a partial custom mode
  # must not write JSON null values into the settings env). model defaults to opus.
  jq -n --arg fref "$fref" --argjson m "$modeobj" '
    def res(v): if v == "fusion" then $fref else v end;
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

# cfl_list_modes — print the modes from config with their slot mappings.
cfl_list_modes() {
  echo "Modes (config: $CFL_CONFIG):"
  jq -r '.modes | to_entries[]
    | "  \(.key): opus=\(.value.opus) sonnet=\(.value.sonnet) haiku=\(.value.haiku) subagent=\(.value.subagent)"' "$CFL_CONFIG"
  echo "  ('fusion' resolves to: $(cfl_fusion_ref))"
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
        local slug pinfo pm pt
        slug="$(cfl_cfg '.preset_slug')"
        if pinfo="$(cfl_or_get "$key" "presets/$slug" 2>/dev/null)"; then
          pm="$(printf '%s' "$pinfo" | jq -r '.data.designated_version.config.model // empty')"
          pt="$(printf '%s' "$pinfo" | jq -r '[.data.designated_version.config.tools[]?.type] | index("openrouter:fusion") // empty')"
          if [ "$pm" = "openrouter/fusion" ] && [ -n "$pt" ]; then
            _d_ok "preset '$slug' configured (custom panel)"
            cfl_preset_ready || _d_warn "PRESET_READY marker missing or stale" "run ./setup.sh to write it"
            # Show the live panel exactly as deployed, then diff it against the
            # config setup.sh builds from (reuses pinfo — no extra API call).
            local live_panel live_judge live_tc cfg_panel cfg_judge
            live_panel="$(printf '%s' "$pinfo" | jq -r '[.data.designated_version.config.tools[]? | select(.type=="openrouter:fusion").parameters.analysis_models[]?] | join(", ")')"
            live_judge="$(printf '%s' "$pinfo" | jq -r '[.data.designated_version.config.tools[]? | select(.type=="openrouter:fusion").parameters.model][0] // "?"')"
            live_tc="$(printf '%s' "$pinfo" | jq -r '.data.designated_version.config.tool_choice // "?"')"
            _d_det "panel: $live_panel"
            _d_det "judge: $live_judge"
            _d_det "tool_choice: $live_tc"
            cfg_panel="$(cfl_cfg '.panel_models | join(", ")')"
            cfg_judge="$(cfl_cfg '.judge_model')"
            if [ "$live_panel" = "$cfg_panel" ] && [ "$live_judge" = "$cfg_judge" ]; then
              _d_ok "preset matches config (panel + judge in sync)"
            else
              _d_warn "preset differs from config — re-run ./setup.sh to sync"
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
          _d_warn "preset '$slug' not found for this key" "run ./setup.sh (launcher uses fallback '$(cfl_cfg '.fallback // "openrouter/fusion"')' until then)"
        fi
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
