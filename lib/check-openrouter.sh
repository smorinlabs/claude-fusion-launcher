#!/usr/bin/env bash
# claude-openrouter pre-flight check: warn (to stderr) if OpenRouter is unreachable or
# the key is rejected, with a hint to run the doctor. Non-blocking (always exits 0).
#
# The launcher runs this just before starting Claude Code. (A SessionStart hook
# DOES execute — even from a --settings file — but Claude Code currently discards
# SessionStart hook OUTPUT under --init-only/new sessions (anthropics/claude-code#10373),
# so it can't show this hint. A pre-flight prints reliably. Verified on 2.1.177.)
# Skip with COL_SKIP_PRECHECK=1.
set -uo pipefail

# The launcher exports the key as ANTHROPIC_AUTH_TOKEN; fall back to OPENROUTER_API_KEY.
key="${ANTHROPIC_AUTH_TOKEN:-${OPENROUTER_API_KEY:-}}"

# With a key: check reachability AND auth via /key. Without: just reachability.
curl_args=(-fsS -m 5 -o /dev/null)
if [ -n "$key" ]; then
  url="https://openrouter.ai/api/v1/key"
  curl_args+=(-H "Authorization: Bearer $key")
else
  url="https://openrouter.ai/api/v1/models"
fi

if command -v curl >/dev/null 2>&1 && curl "${curl_args[@]}" "$url" 2>/dev/null; then
  exit 0   # reachable (and key valid if provided) — stay silent
fi

{
  echo "⚠ claude-openrouter: can't reach or authenticate OpenRouter — requests will fail."
  echo "  Diagnose it:  claude-openrouter doctor   (checks network, key, credits, and your preset)"
} >&2
exit 0
