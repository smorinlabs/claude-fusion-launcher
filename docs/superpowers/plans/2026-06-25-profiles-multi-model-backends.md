# Profiles + Multi-Model Backends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the launcher point Claude Code at any OpenRouter backend — a named fusion preset, a named model-slug alias, or a raw direct slug — selected via a new `--profile`/`--backend` layer composed with the existing modes.

**Architecture:** Introduce a `profiles` catalog in the config (each profile is `type:"fusion"` or `type:"model"`). Modes stay global; the slot keyword `"fusion"` becomes `"backend"` and resolves to the active profile's target. `setup.sh` creates a preset per fusion profile (per-slug readiness markers). The launcher gains `--profile`, `--backend`, and a `profiles` subcommand; the default mode becomes `extreme`.

**Tech Stack:** Bash (`set -euo pipefail`), `jq`, `curl`, `claude` CLI. Tests are NO-COST checks in `tests/smoke.sh` (stub `claude`/`curl`, assert on rendered JSON and function output). Lint via `shellcheck`. Runner: `just` / `make`.

## Global Constraints

- Clean break: the config no longer reads top-level `preset_slug`/`panel_models`/`judge_model`/`fallback`. They live inside each fusion profile. No back-compat shim. (spec: Decisions, Out of scope)
- Slot keyword is `"backend"` only. The `"fusion"` keyword is removed (no alias). (spec: Decisions)
- Default mode when none given is `extreme`, **uniformly for every profile** (no per-profile `default_mode`). (spec: Decisions)
- `--profile` and `--backend` are mutually exclusive (error if both). (spec: Resolution semantics)
- Preset readiness is per-slug markers at `$CFL_STATE_DIR/presets/<slug>.json`. Existing single `PRESET_READY` users fall to fallback + warning until they re-run `setup.sh`. (spec: Per-profile preset readiness)
- Config filename stays `config/modes.json(.example)`; `$CLAUDE_FUSION_CONFIG` override unchanged. (spec: Config schema)
- Secret hygiene unchanged: key resolved per-run, scoped to a subshell, never logged. (existing `bin/claude-fusion`)
- Every script stays `shellcheck`-clean (smoke check #1 lints `bin/claude-fusion setup.sh lib/common.sh lib/check-openrouter.sh tests/smoke.sh .githooks/pre-commit`).

---

## File Structure

- `config/modes.json.example` — **rewrite** to the profiles schema (catalog + `default_profile`/`default_mode` + modes using `"backend"`).
- `lib/common.sh` — **modify**: forward args in `cfl_cfg`; add `cfl_resolve_profile`, `cfl_resolve_mode`, `cfl_profile_type`, `cfl_profile_backend_ref`, `cfl_backend_ref`, `cfl_fusion_profiles`, `cfl_list_profiles`; replace `cfl_preset_ready` (per-slug) and remove `cfl_preset_marker_slug`/`cfl_fusion_ref`; change `cfl_render_settings` signature + `"backend"` keyword + `extreme.default` slot; update `cfl_list_modes`; make `cfl_doctor` profile-aware.
- `setup.sh` — **modify**: `--profile` flag; iterate fusion profiles (all by default); per-slug markers; skip model profiles with a clear message.
- `bin/claude-fusion` — **modify**: `--profile`/`--backend` flags, `profiles` subcommand, default mode `extreme`, mutual exclusion, profile-aware preset warning, richer `--show-settings`.
- `tests/smoke.sh` — **modify**: migrate render/marker/doctor checks to the new schema; add profile/backend/subcommand/setup-loop checks.
- `justfile` — **modify**: `run` recipe default mode `main` → `extreme`.
- `README.md` — **modify**: Profiles section; updated modes/keyword/default-mode wording; upgrade re-run note.
- `PROJECTS.md` — **modify**: add Project P03.

---

## Task 1: Config schema + backend resolution core

Rewrites the config to the profiles schema and reworks `lib/common.sh` resolution so modes render against a resolved backend. Migrates the smoke checks that depend on the old schema/signature. This task leaves `./tests/smoke.sh` green for everything except setup/launcher/doctor checks touched in later tasks (those are migrated in their own tasks).

**Files:**
- Rewrite: `config/modes.json.example`
- Modify: `lib/common.sh` (`cfl_cfg`, new resolvers, `cfl_preset_ready`, `cfl_render_settings`, `cfl_list_modes`; remove `cfl_fusion_ref`, `cfl_preset_marker_slug`)
- Test: `tests/smoke.sh` (checks #2, #4, #5, #6, #6b, #6c, #7, #8c)

**Interfaces:**
- Produces:
  - `cfl_cfg <jq-args...>` — runs `jq -r "$@" "$CFL_CONFIG"` (now forwards `--arg`).
  - `cfl_resolve_profile <cli_profile>` → profile name (`cli` else `.default_profile`).
  - `cfl_resolve_mode <cli_mode>` → mode name (`cli` else `.default_mode` else `extreme`).
  - `cfl_profile_type <profile>` → `fusion` | `model` | empty.
  - `cfl_profile_backend_ref <profile>` → `@preset/<slug>`|fallback|model-slug (dies on unknown profile).
  - `cfl_backend_ref <profile> <direct_slug>` → `direct_slug` if non-empty, else `cfl_profile_backend_ref <profile>`.
  - `cfl_preset_ready <slug>` → exit 0 iff `$CFL_STATE_DIR/presets/<slug>.json` exists.
  - `cfl_fusion_profiles` → newline-separated names of `type:"fusion"` profiles.
  - `cfl_list_profiles` — human-readable profile listing.
  - `cfl_render_settings <mode> <profile> [direct_slug]` → path to rendered settings JSON; `"backend"` slot keyword resolves via `cfl_backend_ref`.

- [ ] **Step 1: Rewrite the example config to the profiles schema**

Replace the entire contents of `config/modes.json.example` with:

```json
{
  "default_profile": "fusion",
  "default_mode": "extreme",
  "profiles": {
    "fusion": {
      "type": "fusion",
      "preset_slug": "cc-fusion",
      "panel_models": [
        "~anthropic/claude-opus-latest",
        "~openai/gpt-latest",
        "~google/gemini-pro-latest",
        "deepseek/deepseek-v3.2",
        "qwen/qwen3-coder-plus"
      ],
      "judge_model": "~anthropic/claude-opus-latest",
      "fallback": "openrouter/fusion"
    },
    "deepseek": { "type": "model", "model": "deepseek/deepseek-v3.2" },
    "qwen": { "type": "model", "model": "qwen/qwen3-coder-plus" }
  },
  "modes": {
    "subagent": { "default": "opus", "opus": "~anthropic/claude-opus-latest", "sonnet": "~anthropic/claude-sonnet-latest", "haiku": "~anthropic/claude-haiku-latest", "subagent": "backend" },
    "main": { "default": "opus", "opus": "backend", "sonnet": "~anthropic/claude-sonnet-latest", "haiku": "~anthropic/claude-haiku-latest", "subagent": "backend" },
    "extreme": { "default": "backend", "opus": "backend", "sonnet": "backend", "haiku": "backend", "subagent": "backend" }
  }
}
```

- [ ] **Step 2: Migrate the smoke checks for this task to the new schema/signature**

In `tests/smoke.sh`:

(a) Replace check #4 (each shipped mode renders) so it passes a profile:

```bash
# 4. each shipped mode renders to valid JSON (profile-aware signature)
for m in subagent main extreme; do
  out="$(cfl_render_settings "$m" fusion)"
  if jq -e . "$out" >/dev/null 2>&1; then
    ok "render mode: $m"
  else
    bad "render mode: $m"
  fi
done
```

(b) Replace checks #5, #6, #6b, #6c with profile/marker-aware versions:

```bash
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
```

(c) Replace check #7 (subagent mapping) and #8c (partial mode) to the new signature/keyword:

```bash
# 7. subagent mode keeps a plain Opus main but fusion subagent
sub_out="$(cfl_render_settings subagent fusion)"
sub="$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL' "$sub_out")"
mainslot="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$sub_out")"
if [ "$sub" = "@preset/cc-fusion" ] && [ "$mainslot" = "~anthropic/claude-opus-latest" ]; then
  ok "subagent slot mapping"
else
  bad "subagent slot mapping" "main=$mainslot sub=$sub"
fi
```

```bash
# 8c. a partial custom mode OMITS undefined slots (must not write null env keys)
partcfg="$(mktemp)"
jq '.modes.partial = {"default":"opus","opus":"backend","subagent":"backend"}' "$CFL_CONFIG" > "$partcfg"
old_cfg="$CFL_CONFIG"; CFL_CONFIG="$partcfg"; part_out="$(cfl_render_settings partial fusion)"; CFL_CONFIG="$old_cfg"
nulls="$(jq -c '[.env[] | select(. == null)] | length' "$part_out")"
has_sonnet="$(jq -c '.env | has("ANTHROPIC_DEFAULT_SONNET_MODEL")' "$part_out")"
if [ "$nulls" = "0" ] && [ "$has_sonnet" = "false" ]; then ok "partial mode omits null slots"; else bad "partial mode omits null slots" "nulls=$nulls sonnetKey=$has_sonnet"; fi
rm -f "$partcfg"
```

Also update checks #8 and #8b to the new render signature (they reuse `ext_out`):

```bash
# 8. advisor disabled in every rendered profile
ext_out="$(cfl_render_settings extreme fusion)"
if jq -e '.env.CLAUDE_CODE_DISABLE_ADVISOR_TOOL == "1"' "$ext_out" >/dev/null; then ok "advisor disabled"; else bad "advisor disabled"; fi
```

- [ ] **Step 3: Run smoke to verify the migrated checks FAIL**

Run: `./tests/smoke.sh`
Expected: FAIL — checks #4–#8c fail because `cfl_render_settings` still takes one arg / uses the `"fusion"` keyword and `cfl_preset_ready` still reads the old marker. (Later checks #13–#25 may also fail; they are migrated in Tasks 2–5.)

- [ ] **Step 4: Update `cfl_cfg` to forward all args**

In `lib/common.sh`, replace:

```bash
cfl_cfg() { jq -r "$1" "$CFL_CONFIG"; }
```

with:

```bash
# cfl_cfg <jq-args...> — query the config (raw output). Forwards extra args
# (e.g. --arg) so callers can pass profile names safely.
cfl_cfg() { jq -r "$@" "$CFL_CONFIG"; }
```

- [ ] **Step 5: Replace the fusion-ref/marker block with profile resolvers**

In `lib/common.sh`, delete `cfl_preset_marker_slug`, the old `cfl_preset_ready`, and `cfl_fusion_ref` (the block from `cfl_preset_marker_slug() {` through the end of `cfl_fusion_ref() {...}`), and replace with:

```bash
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
cfl_profile_type() { cfl_cfg --arg p "$1" '.profiles[$p].type // empty'; }

# cfl_preset_ready <slug> — true iff the per-slug readiness marker exists.
cfl_preset_ready() { [ -f "$CFL_STATE_DIR/presets/$1.json" ]; }

# cfl_fusion_profiles — names of all type:"fusion" profiles, one per line.
cfl_fusion_profiles() {
  cfl_cfg '.profiles | to_entries[] | select(.value.type=="fusion") | .key'
}

# cfl_profile_backend_ref <profile> — resolve a NAMED profile to its backend
# string. fusion -> @preset/<slug> when ready else fallback; model -> the slug.
cfl_profile_backend_ref() {
  local p="$1" type
  type="$(cfl_profile_type "$p")"
  case "$type" in
    model) cfl_cfg --arg p "$p" '.profiles[$p].model // empty' ;;
    fusion)
      local slug fallback
      slug="$(cfl_cfg --arg p "$p" '.profiles[$p].preset_slug // empty')"
      fallback="$(cfl_cfg --arg p "$p" '.profiles[$p].fallback // "openrouter/fusion"')"
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
      elif .value.type=="model"  then "  \(.key) (model): \(.value.model)"
      else "  \(.key) (unknown type)" end' "$CFL_CONFIG"
  printf '  default_profile: %s   default_mode: %s\n' "$(cfl_cfg '.default_profile // "—"')" "$(cfl_cfg '.default_mode // "extreme"')"
}
```

- [ ] **Step 6: Change `cfl_render_settings` to take a profile/backend and use the `"backend"` keyword**

In `lib/common.sh`, replace the `cfl_render_settings` function with:

```bash
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
```

- [ ] **Step 7: Update `cfl_list_modes` to describe the `"backend"` keyword**

In `lib/common.sh`, replace `cfl_list_modes` with:

```bash
# cfl_list_modes — print the modes from config with their slot mappings.
cfl_list_modes() {
  echo "Modes (config: $CFL_CONFIG):"
  jq -r '.modes | to_entries[]
    | "  \(.key): default=\(.value.default) opus=\(.value.opus) sonnet=\(.value.sonnet) haiku=\(.value.haiku) subagent=\(.value.subagent)"' "$CFL_CONFIG"
  echo "  ('backend' resolves to the active profile's target — see 'claude-fusion profiles')"
}
```

- [ ] **Step 8: Run smoke; verify Task-1 checks PASS**

Run: `./tests/smoke.sh`
Expected: checks #1–#8c, plus #2 (`modes.json.example valid`) PASS. Checks #13–#25 (modes/show-settings/doctor/setup/just) may still fail — they are addressed in Tasks 2–5. Confirm no shellcheck failures (#1).

- [ ] **Step 9: Commit**

```bash
git add config/modes.json.example lib/common.sh tests/smoke.sh
git commit -m "feat: profiles catalog + backend resolution core (v0.3.0)"
```

---

## Task 2: setup.sh — per-profile preset creation

Makes `setup.sh` create a preset for every fusion profile by default, `--profile NAME` for one, per-slug markers, and a clear skip for model profiles.

**Files:**
- Modify: `setup.sh`
- Test: `tests/smoke.sh` (migrate #22; add multi-profile success + marker + model-skip checks)

**Interfaces:**
- Consumes: `cfl_fusion_profiles`, `cfl_profile_type`, `cfl_cfg --arg`, `cfl_preset_ready`, `CFL_STATE_DIR`, `OR_API` (from Task 1 / existing).
- Produces: markers at `$CFL_STATE_DIR/presets/<slug>.json` (`{preset_slug, verified_at}`). Exit non-zero if any requested preset fails.

- [ ] **Step 1: Add the new smoke checks (migrate #22, add setup-loop checks)**

In `tests/smoke.sh`, replace check #22 and add the new checks immediately after it:

```bash
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
```

- [ ] **Step 2: Run smoke; verify the new setup checks FAIL**

Run: `./tests/smoke.sh`
Expected: #22b/#22c FAIL (`setup.sh` has no `--profile`, doesn't loop, writes the old single marker). #22 may also fail since markers/exit semantics changed.

- [ ] **Step 3: Add `--profile` parsing to setup.sh**

In `setup.sh`, replace the arg loop with one that also accepts `--profile`:

```bash
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
```

- [ ] **Step 4: Replace the single-preset creation with a per-profile loop**

In `setup.sh`, replace everything from `slug="$(cfl_cfg '.preset_slug')"` through the final `fi` of the create/verify block with:

```bash
# Decide which fusion profiles to create.
profiles_to_do=()
if [ -n "$only_profile" ]; then
  ptype="$(cfl_profile_type "$only_profile")"
  [ -n "$ptype" ] || cfl_die "unknown profile '$only_profile' — available: $(cfl_cfg '.profiles | keys | join(", ")')"
  if [ "$ptype" != "fusion" ]; then
    echo "setup: profile '$only_profile' is type '$ptype' — nothing to set up (only fusion profiles need a preset)."
    exit 0
  fi
  profiles_to_do=("$only_profile")
else
  while IFS= read -r p; do [ -n "$p" ] && profiles_to_do+=("$p"); done < <(cfl_fusion_profiles)
  [ "${#profiles_to_do[@]}" -gt 0 ] || cfl_die "no fusion profiles in config — nothing to set up"
fi

mkdir -p "$CFL_STATE_DIR/presets"
overall_fail=0
for prof in "${profiles_to_do[@]}"; do
  slug="$(cfl_cfg --arg p "$prof" '.profiles[$p].preset_slug')"
  judge="$(cfl_cfg --arg p "$prof" '.profiles[$p].judge_model')"
  panel="$(jq -c --arg p "$prof" '.profiles[$p].panel_models' "$CFL_CONFIG")"

  echo "setup: creating OpenRouter preset '$slug' (profile '$prof')"
  echo "       panel: $(echo "$panel" | jq -r 'join(", ")')"
  echo "       judge: $judge"

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
    jq -n --arg preset_slug "$slug" --arg verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{preset_slug: $preset_slug, verified_at: $verified_at}' > "$CFL_STATE_DIR/presets/$slug.json"
    echo "setup: OK — preset '$slug' created (model=$got_model, fusion tool persisted)."
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
```

> Note: `cfl_die` retains the original `preset creation failed` text so smoke #22 still matches. The per-`slug` `cfl_warn` also carries it for the single-profile example case.

- [ ] **Step 5: Run smoke; verify setup checks PASS**

Run: `./tests/smoke.sh`
Expected: #22, #22b, #22c PASS; #1 (shellcheck) still clean.

- [ ] **Step 6: Commit**

```bash
git add setup.sh tests/smoke.sh
git commit -m "feat: setup creates a preset per fusion profile with per-slug markers"
```

---

## Task 3: Launcher CLI — profiles, backend, default mode

Adds `--profile`/`--backend`, the `profiles` subcommand, the `extreme` default, mutual exclusion, a profile-aware preset warning, and richer `--show-settings`. Also flips the `just run` default to `extreme`.

**Files:**
- Modify: `bin/claude-fusion`
- Modify: `justfile` (`run` default)
- Test: `tests/smoke.sh` (migrate #13, #14, #14b; add profile/backend/exclusion/default-mode checks; migrate #25 default-mode sub-check)

**Interfaces:**
- Consumes: `cfl_resolve_profile`, `cfl_resolve_mode`, `cfl_profile_type`, `cfl_backend_ref`, `cfl_render_settings <mode> <profile> [direct]`, `cfl_list_profiles`, `cfl_preset_ready`, `cfl_cfg --arg` (Task 1).
- Produces: CLI flags `--profile NAME`, `--backend SLUG`; subcommand `profiles`.

- [ ] **Step 1: Add/modify smoke checks for the launcher**

In `tests/smoke.sh`:

(a) Add a `profiles` subcommand check right after check #13:

```bash
# 13b. 'profiles' subcommand lists profiles + targets
profiles_out="$(bin/claude-fusion profiles 2>/dev/null || true)"
case "$profiles_out" in *"fusion (fusion):"*) ok "profiles subcommand" ;; *) bad "profiles subcommand" "$profiles_out" ;; esac
```

(b) Replace check #14 (show-settings) so the dry-run prints the active profile and uses the default mode, and add backend/exclusion checks:

```bash
# 14. --show-settings renders valid JSON and reports the active profile
ss_out="$(bin/claude-fusion --show-settings --profile fusion --mode main 2>/dev/null || true)"
ss_json="$(printf '%s' "$ss_out" | sed -n '/^----$/,$p' | tail -n +2)"
if printf '%s' "$ss_json" | jq -e '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' >/dev/null 2>&1 \
  && [[ "$ss_out" == *"profile:"* ]]; then ok "--show-settings renders JSON"; else bad "--show-settings renders JSON" "$ss_out"; fi

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
```

(c) Migrate the `just run` default-mode sub-check in #25 (the `default_argv_out` block) from `main` to `extreme`:

```bash
default_argv_out="$tmpstate/default-claude-argv.txt"
if PATH="$fakebin:$PATH" CLAUDE_ARGV_OUT="$default_argv_out" CFL_SKIP_PRECHECK=1 OPENROUTER_API_KEY=test just --quiet run >/dev/null 2>&1 \
  && grep -Eq '/extreme\.json$' "$default_argv_out"; then
  ok "just run defaults to extreme"
else
  bad "just run defaults to extreme" "$(tr '\n' ' ' < "$default_argv_out" 2>/dev/null || true)"
fi
```

- [ ] **Step 2: Run smoke; verify the new launcher checks FAIL**

Run: `./tests/smoke.sh`
Expected: #13b, #14, #14c, #14d, #14e and the migrated #25 sub-check FAIL (flags/subcommand/defaults not implemented yet).

- [ ] **Step 3: Add the `profiles` subcommand and default mode**

In `bin/claude-fusion`, change the default mode constant:

```bash
# Default = the configured default_mode (extreme): the active backend in every slot.
DEFAULT_MODE="extreme"
```

Add a `profiles)` case to the subcommand `case` block (next to `modes)`):

```bash
  profiles)
    cfl_require jq
    cfl_load_config
    cfl_list_profiles
    exit 0
    ;;
```

- [ ] **Step 4: Add `--profile`/`--backend` parsing and mutual exclusion**

In `bin/claude-fusion`, in the launcher arg loop, initialize the new vars near the others:

```bash
mode=""
profile=""
backend=""
profile_set=0
backend_set=0
```

(Replace the existing `mode="$DEFAULT_MODE"` initialization with `mode=""`; keep `key`, `keyfile`, `go`, `mode_set`, `show`, `cost`, `args` as-is.)

Because `mode` now starts empty, fix the no-args TTY prompt so it still shows the default. In the "No actionable input" block, change:

```bash
    printf "\nStart now in the default mode '%s'? [y/N] " "$mode"
```

to:

```bash
    printf "\nStart now with the defaults (profile from config, mode '%s')? [y/N] " "$DEFAULT_MODE"
```

Add these cases inside the `while [ $# -gt 0 ]` loop:

```bash
    --profile) profile="${2:?--profile needs a value}"; profile_set=1; shift 2;;
    --profile=*) profile="${1#*=}"; profile_set=1; shift;;
    --backend) backend="${2:?--backend needs a value}"; backend_set=1; shift 2;;
    --backend=*) backend="${1#*=}"; backend_set=1; shift;;
```

After the loop, enforce mutual exclusion and resolve defaults (place immediately before the "No actionable input" block):

```bash
if [ "$profile_set" -eq 1 ] && [ "$backend_set" -eq 1 ]; then
  cfl_die "--profile and --backend are mutually exclusive (a raw --backend slug has no named profile)"
fi
```

Update the "No actionable input" guard to also count profile/backend:

```bash
if [ "$go" -eq 0 ] && [ "$mode_set" -eq 0 ] && [ "$show" -eq 0 ] \
   && [ "$profile_set" -eq 0 ] && [ "$backend_set" -eq 0 ] && [ ${#args[@]} -eq 0 ]; then
```

- [ ] **Step 5: Resolve mode/profile after config load and render with them**

In `bin/claude-fusion`, after `cfl_load_config` and before the existing `settings="$(cfl_render_settings "$mode")"` line, replace that render line with:

```bash
mode="$(cfl_resolve_mode "$mode")"
if [ "$backend_set" -eq 0 ]; then
  profile="$(cfl_resolve_profile "$profile")"
fi
settings="$(cfl_render_settings "$mode" "$profile" "$backend")"
```

- [ ] **Step 6: Update `--show-settings` output to report the profile/backend**

In `bin/claude-fusion`, replace the dry-run block (`if [ "$show" -eq 1 ]; then ... fi`) with:

```bash
if [ "$show" -eq 1 ]; then
  echo "mode:       $mode"
  if [ "$backend_set" -eq 1 ]; then
    echo "profile:    (none — direct --backend)"
  else
    echo "profile:    $profile ($(cfl_profile_type "$profile"))"
  fi
  echo "config:     $CFL_CONFIG"
  echo "backend:    $(cfl_backend_ref "$profile" "$backend")"
  echo "settings:   $settings"
  echo "----"
  jq . "$settings"
  exit 0
fi
```

- [ ] **Step 7: Make the preset-not-ready warning profile-aware**

In `bin/claude-fusion`, replace the existing line:

```bash
cfl_preset_ready || cfl_warn "preset not set up for slug '$(cfl_cfg '.preset_slug')' — using fallback '$(cfl_cfg '.fallback // "openrouter/fusion"')'. Run ./setup.sh for your custom panel."
```

with:

```bash
if [ "$backend_set" -eq 0 ] && [ "$(cfl_profile_type "$profile")" = "fusion" ]; then
  pslug="$(cfl_cfg --arg p "$profile" '.profiles[$p].preset_slug // empty')"
  cfl_preset_ready "$pslug" || cfl_warn "preset not set up for profile '$profile' (slug '$pslug') — using fallback '$(cfl_cfg --arg p "$profile" '.profiles[$p].fallback // "openrouter/fusion"')'. Run ./setup.sh."
fi
```

- [ ] **Step 8: Update the usage text and `just run` default**

In `bin/claude-fusion` `usage()`, replace the body with text covering the new surface (keep the heredoc style):

```bash
usage() {
  cat <<EOF
claude-fusion — run Claude Code through OpenRouter, on a profile + mode.

Quick start:
  claude-fusion -g                       launch defaults (profile + mode: $DEFAULT_MODE)
  claude-fusion --profile NAME [args…]   pick a backend profile; extra args go to claude
  claude-fusion --backend SLUG [args…]   use a raw OpenRouter slug (no named profile)
  claude-fusion --mode MODE [args…]      pick where the backend goes (see 'modes')
  claude-fusion profiles                 list profiles
  claude-fusion modes                    list modes
  claude-fusion doctor                   health checks (deps, key, credits, presets)

Options:
  -g, --go                 launch the defaults, no extra args needed
  --profile NAME           backend profile (default: config .default_profile)
  --backend SLUG           raw OpenRouter model slug (mutually exclusive with --profile)
  --mode MODE              where the backend goes (default: $DEFAULT_MODE)
  --key KEY                OpenRouter key      (precedence: --key > --key-file > \$OPENROUTER_API_KEY)
  --key-file FILE          file with OPENROUTER_API_KEY=…
  --show-settings, --dry-run   print the resolved profile/backend/settings and exit
  --cost                   report OpenRouter spend for the session
  -h, --help               this help

Run ./setup.sh once to create your fusion profiles' presets (otherwise the fallback is used).
EOF
}
```

In `justfile`, change the `run` recipe default:

```just
# run Claude Code with a mode (default: extreme). e.g. `just run main -p "hi"`
run mode="extreme" *args:
    mode="$1"; shift; bin/claude-fusion --mode "$mode" "$@"
```

- [ ] **Step 9: Run smoke; verify launcher checks PASS**

Run: `./tests/smoke.sh`
Expected: #13, #13b, #14, #14b, #14c, #14d, #14e, #15, #16, #25 PASS; #1 shellcheck clean.

- [ ] **Step 10: Commit**

```bash
git add bin/claude-fusion justfile tests/smoke.sh
git commit -m "feat: launcher --profile/--backend, profiles subcommand, extreme default"
```

---

## Task 4: doctor — profile-aware

Rewrites doctor's preset section to iterate fusion profiles (preset + drift per profile) and adds a profiles summary.

**Files:**
- Modify: `lib/common.sh` (`cfl_doctor`)
- Test: `tests/smoke.sh` (migrate #20)

**Interfaces:**
- Consumes: `cfl_fusion_profiles`, `cfl_cfg --arg`, `cfl_preset_ready`, `cfl_or_get`, `cfl_list_profiles` (Task 1).

- [ ] **Step 1: Migrate the doctor smoke check (#20)**

In `tests/smoke.sh`, in check #20, the stubbed presets respond on `presets/cc-fusion`. The example config's only fusion profile is `fusion` (slug `cc-fusion`), so the existing stub URL still matches. Update the build of `synced_preset`/`drift_preset` to read from the profile path, and keep the assertions (they already match doctor's intended output strings):

```bash
synced_preset="$(jq -nc \
  --argjson panel "$(jq -c '.profiles.fusion.panel_models' "$CFL_CONFIG")" \
  --arg judge "$(jq -r '.profiles.fusion.judge_model' "$CFL_CONFIG")" \
  '{data:{designated_version:{config:{model:"openrouter/fusion",tool_choice:"required",
    tools:[{type:"openrouter:fusion",parameters:{model:$judge,analysis_models:$panel}}]}}}}')"
drift_preset="$(printf '%s' "$synced_preset" \
  | jq -c '.data.designated_version.config.tools[0].parameters.analysis_models[0]="zzz/drifted-model"')"
```

Add a profiles-summary assertion to the success branch of #20 — change the `doctor_ok_out` condition to also require the summary line:

```bash
  && "$doctor_ok_out" == *"fusion (fusion):"* \
```

(Insert that line among the other `&&` clauses for `doctor_ok_out` in the `if [[ ... ]]` test.)

- [ ] **Step 2: Run smoke; verify #20 FAILS**

Run: `./tests/smoke.sh`
Expected: #20 FAILS — doctor still reads `.preset_slug` and prints no profiles summary.

- [ ] **Step 3: Add a profiles summary to doctor's config section**

In `lib/common.sh` `cfl_doctor`, in the `--- config ---` section, after the existing `_d_ok "config: ..."`/`_d_no ...` block, add:

```bash
  if [ -f "$CFL_CONFIG" ] && jq -e . "$CFL_CONFIG" >/dev/null 2>&1; then
    while IFS= read -r line; do _d_det "$line"; done < <(cfl_list_profiles)
  fi
```

- [ ] **Step 4: Replace doctor's single-preset block with a per-fusion-profile loop**

In `lib/common.sh` `cfl_doctor`, replace the block starting at `local slug pinfo pm pt` and ending at the `fi` that closes `if pinfo="$(cfl_or_get "$key" "presets/$slug" ...)"` (the whole preset check + drift diff) with:

```bash
        local prof slug pinfo pm pt
        while IFS= read -r prof; do
          [ -n "$prof" ] || continue
          slug="$(cfl_cfg --arg p "$prof" '.profiles[$p].preset_slug')"
          if pinfo="$(cfl_or_get "$key" "presets/$slug" 2>/dev/null)"; then
            pm="$(printf '%s' "$pinfo" | jq -r '.data.designated_version.config.model // empty')"
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
              cfg_panel="$(cfl_cfg --arg p "$prof" '.profiles[$p].panel_models | join(", ")')"
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
            _d_warn "preset '$slug' (profile '$prof') not found for this key" "run ./setup.sh (launcher uses the profile's fallback until then)"
          fi
        done < <(cfl_fusion_profiles)
```

- [ ] **Step 5: Run smoke; verify #20 PASSES**

Run: `./tests/smoke.sh`
Expected: #20 PASS (success branch shows `preset 'cc-fusion' configured`, panel includes `qwen/qwen3-coder-plus`, `tool_choice: required`, `matches config`, and `fusion (fusion):` summary; drift branch warns + exits 0; bad-key branch fails). #1 shellcheck clean.

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh tests/smoke.sh
git commit -m "feat: profile-aware doctor (per-fusion-profile preset + drift, profiles summary)"
```

---

## Task 5: Docs + project tracking

Updates the README to the profiles model and records the project. No code; the deliverable is documentation that matches the shipped behavior.

**Files:**
- Modify: `README.md`
- Modify: `PROJECTS.md`

- [ ] **Step 1: Add a Profiles section and update the Modes section in README**

In `README.md`, after the existing "Modes" section, add a "Profiles" section and adjust the modes wording so the keyword reads `backend` and the default mode reads `extreme`. Use this content:

```markdown
## Profiles

A **profile** decides *what* backend powers Claude Code. A **mode** decides *where* that backend is used (see Modes). Pick both: `--profile NAME --mode NAME`. With no `--mode`, the default is `extreme` (the backend in every slot).

Three flavors:

| Flavor | Config | Needs `./setup.sh`? |
|--------|--------|:---:|
| **Fusion preset** — a panel + judge | `"type": "fusion"` (with `preset_slug`, `panel_models`, `judge_model`, `fallback`) | yes |
| **Model alias** — a named OpenRouter slug | `"type": "model"` (with `model`) | no |
| **Direct slug** — a raw slug, no profile | `--backend "vendor/model"` | no |

```bash
claude-fusion --profile fusion --mode main          # fusion as main + subagents
claude-fusion --profile deepseek                     # deepseek in every slot (extreme default)
claude-fusion --backend "qwen/qwen3-coder-plus"      # raw slug, every slot
claude-fusion profiles                               # list profiles and their targets
```

`--profile` and `--backend` are mutually exclusive. Define profiles in `config/modes.json` (copy `config/modes.json.example`); `default_profile` and `default_mode` set the no-flag behavior.

> **Upgrading from v0.2.x:** preset readiness moved to per-slug markers. Re-run `./setup.sh` once after upgrading; until then fusion profiles use their `fallback` (with a warning).
```

Then, in the existing Modes section, replace any `"fusion"` slot-keyword references with `"backend"`, and change the default-mode mention from `main` to `extreme`. (Search the README for the strings `"fusion"` used as a slot value, the `--mode` default description, and `subagent` example text.)

- [ ] **Step 2: Add Project P03 to PROJECTS.md**

In `PROJECTS.md`, append after the P02 block:

```markdown

---

## [ ] Project P03: profiles + multi-model backends (v0.3.0)
**Goal/Requirement**: Add named **profiles** so the launcher can target any OpenRouter
backend — a fusion preset, a model-slug alias, or a raw `--backend` slug — composed with
the existing modes. Clean-break config schema; default mode becomes `extreme`.

**Out of Scope**
- Back-compat shim for the old top-level preset keys, or a `"fusion"` slot-keyword alias.
- Per-profile `default_mode`.

### Tests & Tasks
- [ ] [P03-T01] Config schema (`profiles` catalog, `default_profile`/`default_mode`) + `lib/common.sh` resolvers (`cfl_resolve_profile/_mode`, `cfl_profile_type`, `cfl_backend_ref`, per-slug `cfl_preset_ready`, `cfl_render_settings` with `"backend"` keyword)
- [ ] [P03-T02] `setup.sh`: per-fusion-profile preset creation (all by default, `--profile` for one), per-slug markers, model-profile skip
- [ ] [P03-T03] `bin/claude-fusion`: `--profile`/`--backend`, `profiles` subcommand, `extreme` default, mutual exclusion, profile-aware preset warning, richer `--show-settings`; `just run` default → extreme
- [ ] [P03-T04] `cfl_doctor`: per-fusion-profile preset + drift, profiles summary
- [ ] [P03-T05] README Profiles section + upgrade note; PROJECTS.md
- [ ] [P03-TS01] `tests/smoke.sh`: profile/backend resolution (all 3 flavors), mode×profile render, default precedence, `--profile`/`--backend` mutual exclusion, multi-profile setup + markers, profile-aware doctor
- [ ] [P03-TS02] Live verification: `--profile deepseek -p "..." --output-format json` shows the deepseek slug; `./setup.sh` creates all fusion presets

### Automated Verification
- `make check`, then `just all` (shellcheck + smoke) pass.

### Manual Verification
- `bin/claude-fusion profiles` lists `fusion` (fusion), `deepseek`/`qwen` (model).
- `bin/claude-fusion --profile fusion --mode main --show-settings` → opus + subagent = `@preset/cc-fusion`.
- `bin/claude-fusion --profile deepseek --show-settings` → all slots = `deepseek/deepseek-v3.2`.
- `bin/claude-fusion --backend "qwen/qwen3-coder-plus" --show-settings` → all slots = `qwen/qwen3-coder-plus`.
- `bin/claude-fusion --profile deepseek --backend foo` → error.
- `./setup.sh --key-file ~/.config/smorin/.env` writes markers under `$CFL_STATE_DIR/presets/`.
```

- [ ] **Step 3: Run the full suite**

Run: `make check && just all`
Expected: deps OK; `shellcheck` clean; `smoke: ALL PASS`.

- [ ] **Step 4: Commit**

```bash
git add README.md PROJECTS.md
git commit -m "docs: profiles README section + P03 tracking (v0.3.0)"
```

---

## Final Verification (whole plan)

- [ ] Run `make check && just all` → `smoke: ALL PASS`, shellcheck clean.
- [ ] Live (costs credits): `./setup.sh --key-file ~/.config/smorin/.env` creates all fusion presets; markers exist under `$CFL_STATE_DIR/presets/`.
- [ ] Live: `bin/claude-fusion --profile deepseek -p "say hi" --output-format json` → `modelUsage` keyed by `deepseek/deepseek-v3.2`.
- [ ] Live: `bin/claude-fusion --profile fusion --mode main -p "say hi" --output-format json` → `modelUsage` shows `@preset/cc-fusion`.
- [ ] Tag/release per repo convention once verified (v0.3.0).
