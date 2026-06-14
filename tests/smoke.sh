#!/usr/bin/env bash
# tests/smoke.sh — NO-COST checks (no OpenRouter/Claude API calls).
set -uo pipefail

CFL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$CFL_ROOT" || exit 1
fail=0
note() { printf '%-42s %s\n' "$1" "$2"; }
ok()   { note "$1" "ok"; }
bad()  { note "$1" "FAIL: ${2:-}"; fail=1; }

# 1. shellcheck (if available)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck bin/claude-fusion setup.sh lib/common.sh tests/smoke.sh; then ok "shellcheck"; else bad "shellcheck"; fi
else
  note "shellcheck" "skipped (not installed)"
fi

# 2. example config is valid JSON
if jq -e . config/modes.json.example >/dev/null 2>&1; then ok "modes.json.example valid"; else bad "modes.json.example valid"; fi

# 3. launcher --help works with no config and no key
if bin/claude-fusion --help >/dev/null 2>&1; then ok "launcher --help"; else bad "launcher --help"; fi

# Use the example as config and an isolated state dir for render/key tests.
export CLAUDE_FUSION_CONFIG="$CFL_ROOT/config/modes.json.example"
tmpstate="$(mktemp -d)"
export XDG_CONFIG_HOME="$tmpstate"
trap 'rm -rf "$tmpstate"' EXIT
# shellcheck source=lib/common.sh
. lib/common.sh

# 4. each shipped mode renders to valid JSON
for m in subagent main extreme; do
  out="$(cfl_render_settings "$m")"
  if jq -e . "$out" >/dev/null 2>&1; then
    ok "render mode: $m"
  else
    bad "render mode: $m"
  fi
done

# 5. "fusion" keyword resolves to fallback when preset is NOT set up
opus_main="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$XDG_CONFIG_HOME/claude-fusion/main.json")"
if [ "$opus_main" = "openrouter/fusion" ]; then ok "fusion->fallback (no preset)"; else bad "fusion->fallback (no preset)" "got $opus_main"; fi

# 6. "fusion" keyword resolves to @preset/<slug> once the marker exists
echo "test" > "$XDG_CONFIG_HOME/claude-fusion/PRESET_READY"
out="$(cfl_render_settings main)"
opus_main="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$out")"
if [ "$opus_main" = "@preset/cc-fusion" ]; then ok "fusion->@preset (preset ready)"; else bad "fusion->@preset (preset ready)" "got $opus_main"; fi

# 7. subagent mode keeps a plain Opus main but fusion subagent (re-render now
#    that PRESET_READY exists, so we don't read the stale fallback render).
sub_out="$(cfl_render_settings subagent)"
sub="$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL' "$sub_out")"
mainslot="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$sub_out")"
if [ "$sub" = "@preset/cc-fusion" ] && [ "$mainslot" = "~anthropic/claude-opus-latest" ]; then
  ok "subagent slot mapping"
else
  bad "subagent slot mapping" "main=$mainslot sub=$sub"
fi

# 8. advisor disabled in every rendered profile
ext_out="$(cfl_render_settings extreme)"
if jq -e '.env.CLAUDE_CODE_DISABLE_ADVISOR_TOOL == "1"' "$ext_out" >/dev/null; then ok "advisor disabled"; else bad "advisor disabled"; fi

# 9. key precedence: --key > --key-file > env
k="$(cfl_resolve_key "argkey" "")"
if [ "$k" = "argkey" ]; then ok "key: --key wins"; else bad "key: --key wins" "$k"; fi
kf="$(mktemp)"; printf 'export OPENROUTER_API_KEY=filekey\n' > "$kf"
k="$(OPENROUTER_API_KEY=envkey cfl_resolve_key "" "$kf")"
if [ "$k" = "filekey" ]; then ok "key: --key-file > env"; else bad "key: --key-file > env" "$k"; fi
k="$(OPENROUTER_API_KEY=envkey cfl_resolve_key "" "")"
if [ "$k" = "envkey" ]; then ok "key: env fallback"; else bad "key: env fallback" "$k"; fi
rm -f "$kf"

echo "----"
[ "$fail" -eq 0 ] && echo "smoke: ALL PASS" || echo "smoke: FAILURES above"
exit "$fail"
