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
  if shellcheck bin/claude-fusion setup.sh lib/common.sh lib/check-openrouter.sh tests/smoke.sh .githooks/pre-commit; then ok "shellcheck"; else bad "shellcheck"; fi
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

# 6. "fusion" keyword resolves to @preset/<slug> once the matching marker exists
echo "preset 'cc-fusion' verified at 2000-01-01T00:00:00Z" > "$XDG_CONFIG_HOME/claude-fusion/PRESET_READY"
out="$(cfl_render_settings main)"
opus_main="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$out")"
if [ "$opus_main" = "@preset/cc-fusion" ]; then ok "fusion->@preset (preset ready)"; else bad "fusion->@preset (preset ready)" "got $opus_main"; fi

# 6b. stale markers for a different preset_slug must not route to @preset/<new-slug>
stalecfg="$(mktemp)"
jq '.preset_slug = "cc-fusion-new"' "$CFL_CONFIG" > "$stalecfg"
old_cfg="$CFL_CONFIG"; CFL_CONFIG="$stalecfg"; stale_out="$(cfl_render_settings main)"; CFL_CONFIG="$old_cfg"
stale_opus="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$stale_out")"
if [ "$stale_opus" = "openrouter/fusion" ]; then ok "stale preset marker ignored"; else bad "stale preset marker ignored" "got $stale_opus"; fi
rm -f "$stalecfg"

# 6c. the top-level default model slot also resolves the "fusion" keyword
defcfg="$(mktemp)"
jq '.modes.default_fusion = {"default":"fusion","opus":"~anthropic/claude-opus-latest"}' "$CFL_CONFIG" > "$defcfg"
old_cfg="$CFL_CONFIG"; CFL_CONFIG="$defcfg"; def_out="$(cfl_render_settings default_fusion)"; CFL_CONFIG="$old_cfg"
def_model="$(jq -r '.model' "$def_out")"
if [ "$def_model" = "@preset/cc-fusion" ]; then ok "default slot resolves fusion"; else bad "default slot resolves fusion" "got $def_model"; fi
rm -f "$defcfg"

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

# 8b. rendered env never contains null values (all strings)
if jq -e '[.env[]] | all(type == "string")' "$ext_out" >/dev/null; then ok "env values all strings"; else bad "env values all strings"; fi

# 8c. a partial custom mode OMITS undefined slots (must not write null env keys)
partcfg="$(mktemp)"
jq '.modes.partial = {"default":"opus","opus":"fusion","subagent":"fusion"}' "$CFL_CONFIG" > "$partcfg"
old_cfg="$CFL_CONFIG"; CFL_CONFIG="$partcfg"; part_out="$(cfl_render_settings partial)"; CFL_CONFIG="$old_cfg"
nulls="$(jq -c '[.env[] | select(. == null)] | length' "$part_out")"
has_sonnet="$(jq -c '.env | has("ANTHROPIC_DEFAULT_SONNET_MODEL")' "$part_out")"
if [ "$nulls" = "0" ] && [ "$has_sonnet" = "false" ]; then ok "partial mode omits null slots"; else bad "partial mode omits null slots" "nulls=$nulls sonnetKey=$has_sonnet"; fi
rm -f "$partcfg"

# 9. key precedence: --key > --key-file > env
k="$(cfl_resolve_key "argkey" "")"
if [ "$k" = "argkey" ]; then ok "key: --key wins"; else bad "key: --key wins" "$k"; fi
kf="$(mktemp)"; printf 'export OPENROUTER_API_KEY=filekey\n' > "$kf"
k="$(OPENROUTER_API_KEY=envkey cfl_resolve_key "" "$kf")"
if [ "$k" = "filekey" ]; then ok "key: --key-file > env"; else bad "key: --key-file > env" "$k"; fi
k="$(OPENROUTER_API_KEY=envkey cfl_resolve_key "" "")"
if [ "$k" = "envkey" ]; then ok "key: env fallback"; else bad "key: env fallback" "$k"; fi
rm -f "$kf"

# 10. config resolution: with no override and no modes.json, defaults to the example.
# shellcheck disable=SC2016  # $CFL_CONFIG must expand in the child bash, not here
cfg_resolved="$(cd "$CFL_ROOT" && env -u CLAUDE_FUSION_CONFIG -u CFL_ROOT bash -c '. lib/common.sh; printf "%s" "$CFL_CONFIG"')"
case "$cfg_resolved" in
  */config/modes.json.example) ok "config defaults to example (no setup needed)" ;;
  */config/modes.json)         ok "config uses local modes.json override" ;;
  *) bad "config resolution" "$cfg_resolved" ;;
esac

# 11. launcher runs from an unrelated cwd (run-location / symlink guard)
if ( cd /tmp && "$CFL_ROOT/bin/claude-fusion" --help >/dev/null 2>&1 ); then ok "runs from other cwd"; else bad "runs from other cwd"; fi

# 12. launcher runs via a symlink onto PATH
lns="$(mktemp -d)/cf-link"; ln -s "$CFL_ROOT/bin/claude-fusion" "$lns"
if ( cd /tmp && "$lns" --help >/dev/null 2>&1 ); then ok "runs via symlink"; else bad "runs via symlink"; fi
rm -f "$lns"

# 13. 'modes' subcommand lists shipped modes
# (capture first — `cmd | grep -q` under `set -o pipefail` can SIGPIPE the producer)
modes_out="$(bin/claude-fusion modes 2>/dev/null || true)"
case "$modes_out" in *"subagent:"*) ok "modes subcommand" ;; *) bad "modes subcommand" ;; esac

# 14. --show-settings renders valid JSON without a key or claude
ss_json="$(bin/claude-fusion --show-settings --mode main 2>/dev/null | sed -n '/^----$/,$p' | tail -n +2)"
if printf '%s' "$ss_json" | jq -e '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' >/dev/null 2>&1; then ok "--show-settings renders JSON"; else bad "--show-settings renders JSON"; fi

# 15. no args (non-TTY) prints help and exits 0
if out_help="$(bin/claude-fusion </dev/null 2>&1)" && printf '%s' "$out_help" | grep -q 'claude-fusion'; then ok "no-args help (exit 0)"; else bad "no-args help"; fi

# 16. -h prints help
h_out="$(bin/claude-fusion -h 2>/dev/null || true)"
case "$h_out" in *"Quick start"*) ok "-h help" ;; *) bad "-h help" ;; esac

# 17. doctor runs and reports (no key -> skips account checks; deps may vary in CI)
doc_out="$(bin/claude-fusion doctor </dev/null 2>&1 || true)"
if [[ "$doc_out" == *"claude-fusion doctor"* && "$doc_out" == *"doctor:"* ]]; then ok "doctor reports"; else bad "doctor reports"; fi

# 18. pre-flight connectivity check: script present/executable, wired into launcher,
#     and the rendered settings carry NO (non-functional) hooks block.
if [ -x lib/check-openrouter.sh ]; then ok "pre-flight script executable"; else bad "pre-flight script executable"; fi
if grep -q 'lib/check-openrouter.sh' bin/claude-fusion; then ok "launcher runs pre-flight"; else bad "launcher runs pre-flight"; fi
if jq -e 'has("hooks") | not' "$ext_out" >/dev/null 2>&1; then ok "no dead hooks block in settings"; else bad "no dead hooks block in settings"; fi

# 19. Just recipes preserve spaced variadic args and install to $HOME by default.
fakebin="$tmpstate/fakebin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGV_OUT"
EOS
chmod +x "$fakebin/claude"
argv_out="$tmpstate/claude-argv.txt"
if PATH="$fakebin:$PATH" CLAUDE_ARGV_OUT="$argv_out" CFL_SKIP_PRECHECK=1 just --quiet run main --key test -p "hello world" >/dev/null 2>&1 \
  && grep -Fxq -- "hello world" "$argv_out"; then
  ok "just run preserves spaced args"
else
  bad "just run preserves spaced args" "$(tr '\n' ' ' < "$argv_out" 2>/dev/null || true)"
fi

setup_dry="$(just --dry-run setup --key-file "space path" 2>&1 || true)"
doctor_dry="$(just --dry-run doctor --key-file "space path" 2>&1 || true)"
if [[ "$setup_dry" == *'./setup.sh "$@"'* && "$doctor_dry" == *'bin/claude-fusion doctor "$@"'* ]]; then
  ok "just setup/doctor forward args safely"
else
  bad "just setup/doctor forward args safely"
fi

install_home="$tmpstate/install-home"
mkdir -p "$install_home"
rm -rf "$CFL_ROOT/~"
if HOME="$install_home" just --quiet install >/dev/null 2>&1 \
  && [ -L "$install_home/.local/bin/claude-fusion" ] \
  && [ ! -e "$CFL_ROOT/~/.local/bin/claude-fusion" ]; then
  ok "just install defaults to HOME"
else
  bad "just install defaults to HOME"
fi
rm -rf "$CFL_ROOT/~"

echo "----"
[ "$fail" -eq 0 ] && echo "smoke: ALL PASS" || echo "smoke: FAILURES above"
exit "$fail"
