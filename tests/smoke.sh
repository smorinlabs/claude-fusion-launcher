#!/usr/bin/env bash
# tests/smoke.sh — NO-COST checks (no OpenRouter/Claude API calls).
# shellcheck disable=SC2030,SC2031
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

fakebin="$tmpstate/fakebin"; mkdir -p "$fakebin"
cat > "$fakebin/claude" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "claude smoke"
  exit 0
fi
if [ -n "${CLAUDE_ARGV_OUT:-}" ]; then
  printf '%s\n' "$@" > "$CLAUDE_ARGV_OUT"
fi
EOS
chmod +x "$fakebin/claude"

# 4. each shipped mode renders to valid JSON (profile-aware signature)
for m in subagent main extreme; do
  out="$(cfl_render_settings "$m" fusion)"
  if jq -e . "$out" >/dev/null 2>&1; then
    ok "render mode: $m"
  else
    bad "render mode: $m"
  fi
done

# 5. fusion profile resolves to fallback when its preset is NOT set up
opus_main="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$XDG_CONFIG_HOME/claude-fusion/main.json")"
if [ "$opus_main" = "openrouter/fusion" ]; then ok "fusion->fallback (no preset)"; else bad "fusion->fallback (no preset)" "got $opus_main"; fi

# 6. fusion profile resolves to @preset/<slug> once the per-slug marker exists
mkdir -p "$XDG_CONFIG_HOME/claude-fusion/presets"
printf '{"preset_slug":"cc-fusion","verified_at":"2000-01-01T00:00:00Z"}' > "$XDG_CONFIG_HOME/claude-fusion/presets/cc-fusion.json"
out="$(cfl_render_settings main fusion)"
opus_main="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$out")"
if [ "$opus_main" = "@preset/cc-fusion" ]; then ok "fusion->@preset (preset ready)"; else bad "fusion->@preset (preset ready)" "got $opus_main"; fi

# 6b. a marker for a different slug must NOT route to @preset/<this-slug>
stalecfg="$(mktemp)"
jq '.profiles.fusion.preset_slug = "cc-fusion-new"' "$CFL_CONFIG" > "$stalecfg"
old_cfg="$CFL_CONFIG"; CFL_CONFIG="$stalecfg"; stale_out="$(cfl_render_settings main fusion)"; CFL_CONFIG="$old_cfg"
stale_opus="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$stale_out")"
if [ "$stale_opus" = "openrouter/fusion" ]; then ok "stale preset marker ignored"; else bad "stale preset marker ignored" "got $stale_opus"; fi
rm -f "$stalecfg"

# 6c. the top-level default model slot also resolves the "backend" keyword
defcfg="$(mktemp)"
jq '.modes.default_fusion = {"default":"backend","opus":"~anthropic/claude-opus-latest"}' "$CFL_CONFIG" > "$defcfg"
old_cfg="$CFL_CONFIG"; CFL_CONFIG="$defcfg"; def_out="$(cfl_render_settings default_fusion fusion)"; CFL_CONFIG="$old_cfg"
def_model="$(jq -r '.model' "$def_out")"
if [ "$def_model" = "@preset/cc-fusion" ]; then ok "default slot resolves backend"; else bad "default slot resolves backend" "got $def_model"; fi
rm -f "$defcfg"

# 7. subagent mode keeps a plain Opus main but fusion subagent
sub_out="$(cfl_render_settings subagent fusion)"
sub="$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL' "$sub_out")"
mainslot="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$sub_out")"
if [ "$sub" = "@preset/cc-fusion" ] && [ "$mainslot" = "~anthropic/claude-opus-latest" ]; then
  ok "subagent slot mapping"
else
  bad "subagent slot mapping" "main=$mainslot sub=$sub"
fi

# 8. advisor disabled in every rendered profile
ext_out="$(cfl_render_settings extreme fusion)"
if jq -e '.env.CLAUDE_CODE_DISABLE_ADVISOR_TOOL == "1"' "$ext_out" >/dev/null; then ok "advisor disabled"; else bad "advisor disabled"; fi

# 8b. rendered env never contains null values (all strings)
if jq -e '[.env[]] | all(type == "string")' "$ext_out" >/dev/null; then ok "env values all strings"; else bad "env values all strings"; fi

# 8c. a partial custom mode OMITS undefined slots (must not write null env keys)
partcfg="$(mktemp)"
jq '.modes.partial = {"default":"opus","opus":"backend","subagent":"backend"}' "$CFL_CONFIG" > "$partcfg"
old_cfg="$CFL_CONFIG"; CFL_CONFIG="$partcfg"; part_out="$(cfl_render_settings partial fusion)"; CFL_CONFIG="$old_cfg"
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

# 13b. 'profiles' subcommand lists profiles + targets
profiles_out="$(bin/claude-fusion profiles 2>/dev/null || true)"
case "$profiles_out" in *"fusion (fusion):"*) ok "profiles subcommand" ;; *) bad "profiles subcommand" "$profiles_out" ;; esac

# 14. --show-settings renders valid JSON and reports the active profile
ss_out="$(bin/claude-fusion --show-settings --profile fusion --mode main 2>/dev/null || true)"
ss_json="$(printf '%s' "$ss_out" | sed -n '/^----$/,$p' | tail -n +2)"
if printf '%s' "$ss_json" | jq -e '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' >/dev/null 2>&1 \
  && [[ "$ss_out" == *"profile:"* ]]; then ok "--show-settings renders JSON"; else bad "--show-settings renders JSON" "$ss_out"; fi

# 14b. unknown modes must fail instead of silently rendering defaults
if bin/claude-fusion --show-settings --mode bogus >/dev/null 2>&1; then bad "unknown mode rejected"; else ok "unknown mode rejected"; fi

# 14c. --backend uses the raw slug in all slots under the default (extreme) mode
be_out="$(bin/claude-fusion --show-settings --backend "qwen/qwen3-coder-plus" 2>/dev/null || true)"
be_json="$(printf '%s' "$be_out" | sed -n '/^----$/,$p' | tail -n +2)"
be_default="$(printf '%s' "$be_json" | jq -r '.model')"
be_sub="$(printf '%s' "$be_json" | jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL')"
if [ "$be_default" = "qwen/qwen3-coder-plus" ] && [ "$be_sub" = "qwen/qwen3-coder-plus" ]; then ok "--backend fills all slots (extreme default)"; else bad "--backend fills all slots" "default=$be_default sub=$be_sub"; fi

# 14d. --profile model alias resolves in all slots under default mode
ds_out="$(bin/claude-fusion --show-settings --profile deepseek 2>/dev/null || true)"
ds_json="$(printf '%s' "$ds_out" | sed -n '/^----$/,$p' | tail -n +2)"
ds_default="$(printf '%s' "$ds_json" | jq -r '.model')"
if [ "$ds_default" = "deepseek/deepseek-v3.2" ]; then ok "--profile model alias resolves"; else bad "--profile model alias resolves" "$ds_default"; fi

# 14e. --profile and --backend together is an error
if bin/claude-fusion --show-settings --profile fusion --backend foo >/dev/null 2>&1; then bad "profile+backend mutually exclusive"; else ok "profile+backend mutually exclusive"; fi

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

# 19. check-openrouter covers key/no-key URL choices and warns non-blockingly.
prebin="$tmpstate/prebin"; mkdir -p "$prebin"
cat > "$prebin/curl" <<'EOS'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in https://*) url="$arg" ;; esac
done
printf '%s\n' "$url" >> "$CURL_URL_LOG"
if [ "${CURL_FAIL:-0}" = "1" ]; then exit 7; fi
exit 0
EOS
chmod +x "$prebin/curl"
curl_url_log="$tmpstate/precheck-urls.txt"
PATH="$prebin:$PATH" CURL_URL_LOG="$curl_url_log" lib/check-openrouter.sh >/dev/null 2>&1
PATH="$prebin:$PATH" CURL_URL_LOG="$curl_url_log" OPENROUTER_API_KEY=test lib/check-openrouter.sh >/dev/null 2>&1
pre_fail_out="$(PATH="$prebin:$PATH" CURL_URL_LOG="$curl_url_log" CURL_FAIL=1 OPENROUTER_API_KEY=test lib/check-openrouter.sh 2>&1)"
if grep -Fxq "https://openrouter.ai/api/v1/models" "$curl_url_log" \
  && grep -Fxq "https://openrouter.ai/api/v1/key" "$curl_url_log" \
  && [[ "$pre_fail_out" == *"can't reach"* ]]; then
  ok "pre-flight checks URL paths"
else
  bad "pre-flight checks URL paths" "$(tr '\n' ' ' < "$curl_url_log" 2>/dev/null || true)"
fi

# 20. Doctor account checks are covered with stubbed OpenRouter responses.
# Build an in-sync preset straight from the config so the diff has nothing to flag,
# and a drifted variant (one panel model swapped) that must warn but NOT fail.
synced_preset="$(jq -nc \
  --argjson panel "$(jq -c '.profiles.fusion.panel_models' "$CFL_CONFIG")" \
  --arg judge "$(jq -r '.profiles.fusion.judge_model' "$CFL_CONFIG")" \
  '{data:{designated_version:{config:{model:"openrouter/fusion",tool_choice:"required",
    tools:[{type:"openrouter:fusion",parameters:{model:$judge,analysis_models:$panel}}]}}}}')"
drift_preset="$(printf '%s' "$synced_preset" \
  | jq -c '.data.designated_version.config.tools[0].parameters.analysis_models[0]="zzz/drifted-model"')"

doctor_ok_out="$(
  PATH="$fakebin:$PATH"
  cfl_or_get() {
    if [ "$2" = "key" ]; then
      printf '{"data":{"label":"smoke"}}'
    elif [ "$2" = "credits" ]; then
      printf '{"data":{"total_credits":1,"total_usage":0.25}}'
    elif [ "$2" = "presets/cc-fusion" ]; then
      printf '%s' "$synced_preset"
    else
      return 22
    fi
  }
  cfl_doctor "test" "file:/tmp/key.env"
)"
drift_rc=0
doctor_drift_out="$(
  PATH="$fakebin:$PATH"
  cfl_or_get() {
    if [ "$2" = "key" ]; then
      printf '{"data":{"label":"smoke"}}'
    elif [ "$2" = "credits" ]; then
      printf '{"data":{"total_credits":10,"total_usage":1}}'
    elif [ "$2" = "presets/cc-fusion" ]; then
      printf '%s' "$drift_preset"
    else
      return 22
    fi
  }
  cfl_doctor "test" "env:OPENROUTER_API_KEY"
)" || drift_rc=$?
doctor_bad_out="$(
  PATH="$fakebin:$PATH"
  cfl_or_get() { return 22; }
  cfl_doctor "test"
)"
# shellcheck disable=SC2016  # the $OPENROUTER_API_KEY below is a literal in a glob, not an expansion
if [[ "$doctor_ok_out" == *"key resolved (…test)"* \
  && "$doctor_ok_out" == *"source: file /tmp/key.env"* \
  && "$doctor_ok_out" == *"key valid"* && "$doctor_ok_out" == *"low credits"* \
  && "$doctor_ok_out" == *"preset 'cc-fusion' configured"* \
  && "$doctor_ok_out" == *"qwen/qwen3-coder-plus"* \
  && "$doctor_ok_out" == *"tool_choice: required"* \
  && "$doctor_ok_out" == *"matches config"* \
  && "$doctor_ok_out" == *"fusion (fusion):"* \
  && "$doctor_drift_out" == *'source: env $OPENROUTER_API_KEY'* \
  && "$doctor_drift_out" == *"differs from config"* && "$doctor_drift_out" == *"zzz/drifted-model"* \
  && "$drift_rc" -eq 0 \
  && "$doctor_bad_out" == *"OpenRouter rejected the key"* ]]; then
  ok "doctor account branch covered"
else
  bad "doctor account branch covered" "drift_rc=$drift_rc"
fi

# 21. --cost reports a numeric usage delta with stubbed curl/claude.
costbin="$tmpstate/costbin"; mkdir -p "$costbin"
cost_count="$tmpstate/cost-count.txt"; printf '0' > "$cost_count"
cat > "$costbin/curl" <<'EOS'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in https://*) url="$arg" ;; esac
done
case "$url" in
  */credits)
    n="$(cat "$COST_COUNT")"
    if [ "$n" = "0" ]; then
      printf '1' > "$COST_COUNT"
      printf '{"data":{"total_usage":1}}'
    else
      printf '{"data":{"total_usage":1.25}}'
    fi
    ;;
  *) printf '{"data":{}}' ;;
esac
EOS
cat > "$costbin/claude" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$costbin/curl" "$costbin/claude"
cost_out="$(PATH="$costbin:$PATH" COST_COUNT="$cost_count" CFL_SKIP_PRECHECK=1 bin/claude-fusion --cost --key test -p hi 2>&1)"
if [[ "$cost_out" == *"session cost ~\$0.25"* && "$cost_out" == *"OpenRouter usage \$1 -> \$1.25"* ]]; then ok "--cost reports usage delta"; else bad "--cost reports usage delta" "$cost_out"; fi

# 22. Setup reports non-JSON preset responses instead of aborting on jq parse errors.
setupbin="$tmpstate/setupbin"; mkdir -p "$setupbin"
cat > "$setupbin/curl" <<'EOS'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in https://*) url="$arg" ;; esac
done
case "$url" in
  */key) printf '{"data":{"label":"smoke"}}' ;;
  */credits) printf '{"data":{"total_credits":10,"total_usage":1}}' ;;
  */presets/*/chat/completions) printf '<html>bad gateway</html>' ;;
  *) printf '{"error":{"message":"unexpected URL"}}' ;;
esac
EOS
chmod +x "$setupbin/curl"
setup_out="$(PATH="$setupbin:$PATH" XDG_CONFIG_HOME="$tmpstate/setup-state" ./setup.sh --key test 2>&1)"
setup_rc=$?
if [ "$setup_rc" -ne 0 ] && [[ "$setup_out" == *'<html>bad gateway</html>'* && "$setup_out" == *'preset creation failed'* && "$setup_out" != *'parse error'* ]]; then
  ok "setup handles non-JSON preset response"
else
  bad "setup handles non-JSON preset response" "$setup_out"
fi

# 22b. Setup creates a preset per fusion profile and writes a per-slug marker each.
okbin="$tmpstate/setup-okbin"; mkdir -p "$okbin"
cat > "$okbin/curl" <<'EOS'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in https://*) url="$arg" ;; esac
done
case "$url" in
  */key) printf '{"data":{"label":"smoke"}}' ;;
  */credits) printf '{"data":{"total_credits":10,"total_usage":1}}' ;;
  */presets/*/chat/completions)
    printf '{"data":{"designated_version":{"config":{"model":"openrouter/fusion","tools":[{"type":"openrouter:fusion"}]}}}}' ;;
  *) printf '{"error":{"message":"unexpected URL"}}' ;;
esac
EOS
chmod +x "$okbin/curl"
two_cfg="$(mktemp)"
jq '.profiles["fusion2"] = {"type":"fusion","preset_slug":"cc-fusion-2","panel_models":["deepseek/deepseek-v3.2"],"judge_model":"deepseek/deepseek-v3.2","fallback":"openrouter/fusion"}' "$CFL_CONFIG" > "$two_cfg"
ok_state="$tmpstate/setup-ok-state"
ok_out="$(PATH="$okbin:$PATH" XDG_CONFIG_HOME="$ok_state" CLAUDE_FUSION_CONFIG="$two_cfg" ./setup.sh --key test 2>&1)"
if [ -f "$ok_state/claude-fusion/presets/cc-fusion.json" ] && [ -f "$ok_state/claude-fusion/presets/cc-fusion-2.json" ]; then
  ok "setup creates a marker per fusion profile"
else
  bad "setup creates a marker per fusion profile" "$ok_out"
fi

# 22c. setup --profile <model-profile> creates nothing and exits 0.
skip_out="$(PATH="$okbin:$PATH" XDG_CONFIG_HOME="$tmpstate/setup-skip-state" CLAUDE_FUSION_CONFIG="$two_cfg" ./setup.sh --profile deepseek --key test 2>&1)"
skip_rc=$?
if [ "$skip_rc" -eq 0 ] && [[ "$skip_out" == *"nothing to set up"* ]] && [ ! -d "$tmpstate/setup-skip-state/claude-fusion/presets" ]; then
  ok "setup --profile model skips"
else
  bad "setup --profile model skips" "rc=$skip_rc $skip_out"
fi
rm -f "$two_cfg"

# 23. gitleaks hook falls back to the older protect --staged syntax.
gitleaksbin="$tmpstate/gitleaksbin"; mkdir -p "$gitleaksbin"
gitleaks_log="$tmpstate/gitleaks.log"
cat > "$gitleaksbin/gitleaks" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  git) echo "unknown command git" >&2; exit 2 ;;
  protect) printf '%s\n' "$*" >> "$GITLEAKS_LOG"; exit 0 ;;
  *) exit 2 ;;
esac
EOS
chmod +x "$gitleaksbin/gitleaks"
if PATH="$gitleaksbin:$PATH" GITLEAKS_LOG="$gitleaks_log" .githooks/pre-commit >/dev/null 2>&1 \
  && grep -Fxq "protect --staged --no-banner --redact" "$gitleaks_log"; then
  ok "gitleaks hook supports protect syntax"
else
  bad "gitleaks hook supports protect syntax"
fi

# 24. CI and local recipe entrypoints stay aligned.
ci_file=".github/workflows/ci.yml"
if grep -q 'setup-just' "$ci_file" && grep -q 'make check' "$ci_file" && grep -q 'just all' "$ci_file" && grep -q '^all: lint test' justfile; then
  ok "ci runs declared recipes"
else
  bad "ci runs declared recipes"
fi
if grep -q 'lib/check-openrouter.sh' justfile && grep -q '.githooks/pre-commit' justfile \
  && grep -q 'lib/check-openrouter.sh' Makefile && grep -q '.githooks/pre-commit' Makefile; then
  ok "lint recipes cover shell files"
else
  bad "lint recipes cover shell files"
fi

# 25. Just/Make recipes preserve documented defaults and setup args.
argv_out="$tmpstate/claude-argv.txt"
if PATH="$fakebin:$PATH" CLAUDE_ARGV_OUT="$argv_out" CFL_SKIP_PRECHECK=1 just --quiet run main --key test -p "hello world" >/dev/null 2>&1 \
  && grep -Fxq -- "hello world" "$argv_out"; then
  ok "just run preserves spaced args"
else
  bad "just run preserves spaced args" "$(tr '\n' ' ' < "$argv_out" 2>/dev/null || true)"
fi

default_argv_out="$tmpstate/default-claude-argv.txt"
if PATH="$fakebin:$PATH" CLAUDE_ARGV_OUT="$default_argv_out" CFL_SKIP_PRECHECK=1 OPENROUTER_API_KEY=test just --quiet run >/dev/null 2>&1 \
  && grep -Eq '/extreme\.json$' "$default_argv_out"; then
  ok "just run defaults to extreme"
else
  bad "just run defaults to extreme" "$(tr '\n' ' ' < "$default_argv_out" 2>/dev/null || true)"
fi

setup_dry="$(just --dry-run setup --key-file "space path" 2>&1 || true)"
doctor_dry="$(just --dry-run doctor --key-file "space path" 2>&1 || true)"
if [[ "$setup_dry" == *'./setup.sh "$@"'* && "$doctor_dry" == *'bin/claude-fusion doctor "$@"'* ]]; then
  ok "just setup/doctor forward args safely"
else
  bad "just setup/doctor forward args safely"
fi

make_setup_dry="$(make -n setup ARGS='--key-file /tmp/key' 2>&1 || true)"
if [[ "$make_setup_dry" == *'./setup.sh --key-file /tmp/key'* ]]; then ok "make setup forwards ARGS"; else bad "make setup forwards ARGS" "$make_setup_dry"; fi

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
