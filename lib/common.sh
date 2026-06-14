#!/usr/bin/env bash
# lib/common.sh — shared helpers for claude-fusion-launcher.
# Source from setup.sh and bin/claude-fusion. Not meant to be executed directly.
# shellcheck shell=bash

CFL_ROOT="${CFL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFL_CONFIG="${CLAUDE_FUSION_CONFIG:-$CFL_ROOT/config/modes.json}"
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

# cfl_load_config — ensure the config exists and is valid JSON.
cfl_load_config() {
  [ -f "$CFL_CONFIG" ] || cfl_die "config not found: $CFL_CONFIG (run ./setup.sh, or copy config/modes.json.example)"
  jq -e . "$CFL_CONFIG" >/dev/null 2>&1 || cfl_die "invalid JSON in $CFL_CONFIG"
}

# cfl_cfg <jq-filter> — query the config (raw output).
cfl_cfg() { jq -r "$1" "$CFL_CONFIG"; }

# cfl_fusion_ref — the model string the "fusion" keyword resolves to:
# @preset/<slug> once setup has run, otherwise the configured fallback.
cfl_fusion_ref() {
  local slug fallback
  slug="$(cfl_cfg '.preset_slug')"
  fallback="$(cfl_cfg '.fallback // "openrouter/fusion"')"
  if [ -f "$CFL_PRESET_READY" ]; then printf '@preset/%s' "$slug"; else printf '%s' "$fallback"; fi
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
  jq -n --arg fref "$fref" --argjson m "$modeobj" '
    def res(v): if v == "fusion" then $fref else v end;
    {
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      model: $m.default,
      env: {
        "ANTHROPIC_API_KEY": "",
        "ANTHROPIC_BASE_URL": "https://openrouter.ai/api",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": res($m.opus),
        "ANTHROPIC_DEFAULT_SONNET_MODEL": res($m.sonnet),
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": res($m.haiku),
        "CLAUDE_CODE_SUBAGENT_MODEL": res($m.subagent),
        "CLAUDE_CODE_DISABLE_ADVISOR_TOOL": "1",
        "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "DISABLE_INTERLEAVED_THINKING": "1"
      }
    }' > "$out"
  printf '%s' "$out"
}
