# Profiles + multi-model backends — design

**Date:** 2026-06-25
**Target version:** v0.3.0
**Status:** approved (design), pending implementation plan

## Summary

Today the launcher can only point Claude Code at a single, hardcoded fusion preset
(`cc-fusion`). This adds **profiles**: a first-class, named way to choose *what*
backend powers Claude Code, while keeping the existing **modes** as the way to
choose *where* that backend is deployed across Claude Code's model slots.

A profile is one of two kinds, and there is also a no-profile escape hatch:

1. **Fusion preset** — a named panel + judge; `setup.sh` creates an OpenRouter
   preset for it; resolves to `@preset/<slug>` (or a fallback until set up).
2. **Model alias** — a friendly name for a single OpenRouter model slug; no setup.
3. **Direct slug** — `--backend "<slug>"` on the CLI; a raw slug used as-is, no
   named profile, no setup.

Modes and profiles compose as a matrix: any mode × any profile.

## Background / current architecture

- `bin/claude-fusion` renders a Claude Code settings JSON per `--mode` and launches
  `claude --settings`, with the OpenRouter key scoped to a subshell via
  `ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_BASE_URL=https://openrouter.ai/api`.
- `lib/common.sh` holds resolution helpers. `cfl_fusion_ref` resolves the literal
  keyword `"fusion"` (used in mode slots) to `@preset/<slug>` when a single
  `PRESET_READY` marker exists, else to a configured `fallback`.
- `config/modes.json.example` is the shipped default config: top-level
  `preset_slug` / `panel_models` / `judge_model` / `fallback`, plus a `modes` map
  whose slots (`default`/`opus`/`sonnet`/`haiku`/`subagent`) are model slugs or the
  keyword `"fusion"`.
- `setup.sh` creates the one preset from the top-level panel/judge and writes the
  single `PRESET_READY` marker.
- `doctor` checks deps/key/credits and the one preset (incl. live-vs-config drift).

### Verified assumption (foundational)

The two new flavors require that Claude Code can drive an **arbitrary
non-Anthropic OpenRouter slug** directly (not only inside fusion's server-side
deliberation). This was verified live on 2026-06-25:

```bash
ANTHROPIC_BASE_URL=https://openrouter.ai/api ANTHROPIC_AUTH_TOKEN=$OPENROUTER_API_KEY \
  claude --model "deepseek/deepseek-v3.2" -p "say hi in 3 words" --output-format json
```

Result: `is_error:false`, response returned, `modelUsage` keyed by
`deepseek/deepseek-v3.2` (`provider: Alibaba`), **no preset involved**. OpenRouter
translates the Anthropic `/v1/messages` format to/from the target model. Plain
models lose Anthropic-only server features (e.g. the advisor tool, which the
launcher already disables via `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`) — expected and
acceptable.

## Decisions (from brainstorming)

| # | Decision |
|---|----------|
| Profile scope | A profile bundles a **backend** (fusion preset *or* model alias). Modes stay separate and shared. |
| Modes vs profiles | **Shared global modes + named profiles.** Select both: `--profile NAME --mode NAME`. Plus `--backend SLUG` for a raw direct slug. |
| Three flavors | fusion preset, model alias, direct slug — all supported. |
| Default mode | **No `--mode` → `extreme` for every profile, uniformly** (including fusion). No per-profile `default_mode`. |
| Setup | **Per-profile, all by default.** `setup.sh` creates presets for all fusion profiles; `setup.sh --profile NAME` does one. Alias/direct profiles are skipped. |
| Migration | **Clean break.** Rewrite `config/modes.json.example` to the profiles schema. No back-compat shim for the old top-level keys. |
| Slot keyword | Canonical keyword is **`"backend"`**. The old `"fusion"` keyword is **removed** (no alias) — clean break, no unrequested compat surface. |

## Config schema (clean break)

`config/modes.json.example` (filename kept to avoid churn in resolution logic,
Flox manifest, and `$CLAUDE_FUSION_CONFIG`; it now also holds profiles):

```jsonc
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
    "qwen":     { "type": "model", "model": "qwen/qwen3-coder-plus" }
  },
  "modes": {
    "subagent": { "default": "opus",    "opus": "~anthropic/claude-opus-latest", "sonnet": "~anthropic/claude-sonnet-latest", "haiku": "~anthropic/claude-haiku-latest", "subagent": "backend" },
    "main":     { "default": "opus",    "opus": "backend", "sonnet": "~anthropic/claude-sonnet-latest", "haiku": "~anthropic/claude-haiku-latest", "subagent": "backend" },
    "extreme":  { "default": "backend", "opus": "backend", "sonnet": "backend", "haiku": "backend", "subagent": "backend" }
  }
}
```

Notes:
- `preset_slug` / `panel_models` / `judge_model` / `fallback` move **into** each
  fusion profile (no longer top-level).
- `"backend"` in any mode slot resolves to the active profile's backend target.
- Modes are orthogonal to presets: `extreme` for a model/direct profile just means
  "use that single slug in all 5 slots" — no preset, no fan-out, no extra cost.

## Resolution semantics

**Backend reference** — new `cfl_backend_ref` replaces `cfl_fusion_ref`. Inputs:
the active profile name (or a direct `--backend` slug).

- direct `--backend SLUG` → `SLUG` (used as-is).
- profile `type: model` → `profile.model`.
- profile `type: fusion` → `@preset/<profile.preset_slug>` if that profile's preset
  is ready, else `profile.fallback` (default `openrouter/fusion`).

**Mode resolution precedence:** `--mode` flag > `default_mode` (global). No
per-profile default.

**Profile resolution precedence:** `--backend SLUG` (ad-hoc, no named profile) XOR
`--profile NAME` > `default_profile`. `--backend` and `--profile` are **mutually
exclusive** — providing both is a clear error.

**Settings render** — `cfl_render_settings <mode> <backend-ref>`: same emitter as
today, but the `"backend"` keyword in any slot is substituted with the resolved
backend-ref. Partial custom modes still only emit env keys for defined slots.

## Per-profile preset readiness (marker migration)

The single `$CFL_STATE_DIR/PRESET_READY` file becomes **per-slug markers**:
`$CFL_STATE_DIR/presets/<slug>.json` (each `{ preset_slug, verified_at }`).

- `cfl_preset_ready <profile>` checks the marker for that profile's slug.
- **Migration impact (called out intentionally):** after upgrading, existing users'
  old single `PRESET_READY` no longer counts. Their fusion profile resolves to the
  `fallback` (with the existing non-fatal warning) until they re-run `setup.sh`,
  which writes the new per-slug marker. No data loss; one re-run needed. Documented
  in README + setup output.

## CLI surface (`bin/claude-fusion`)

```
claude-fusion --profile NAME --mode NAME [claude args…]
claude-fusion --profile deepseek                 # default mode (extreme) → deepseek in all slots
claude-fusion --backend "qwen/qwen3-coder-plus"  # raw slug, all slots = qwen (extreme default)
claude-fusion -g                                 # default_profile + default_mode
claude-fusion profiles                           # NEW subcommand: list profiles + resolved targets
claude-fusion modes                              # unchanged (shows backend keyword resolution)
claude-fusion doctor [--profile NAME]            # profile-aware
--show-settings / --dry-run                      # now prints active profile + backend ref + mode
```

New flags: `--profile NAME`, `--backend SLUG`. New subcommand: `profiles`.
`--backend` + `--profile` together → error.

## setup.sh — per-profile

- Default (no `--profile`): iterate every `type: fusion` profile in config; for each,
  create + verify its preset (reusing today's create/verify body, parameterized by
  slug/panel/judge) and write its per-slug marker. Print a per-profile summary.
- `--profile NAME`: do only that profile. If it is not `type: fusion`, print a clear
  "nothing to set up (model/direct profiles need no preset)" message and exit 0.
- Key validation + credit check up front (unchanged).

## doctor — profile-aware

- Print `default_profile`, `default_mode`, and the list of profiles with their kinds
  and resolved targets.
- For each `type: fusion` profile: the existing preset check + live-vs-config drift
  (panel/judge/tool_choice), keyed off that profile's slug + marker.
- For `type: model` profiles: print the slug (no API assertion required; optionally
  a lightweight presence note — implementation may keep this minimal).
- Key/credits/env checks unchanged.

## Out of scope

- No back-compat shim for the old top-level `preset_slug`/`panel_models`/etc.
- No `"fusion"` slot-keyword alias (only `"backend"`).
- No per-profile `default_mode`.
- No renaming of the config file (`config/modes.json` name retained).
- Native-Anthropic advisor through OpenRouter (already disabled; unchanged).
- No automatic migration of the old `PRESET_READY` marker (users re-run `setup.sh`).

## Testing (TDD — tests first)

`tests/smoke.sh` additions:
- Backend resolution per flavor: fusion profile → `@preset/<slug>` when marker
  present, else fallback; model profile → its slug; `--backend SLUG` → the slug.
- Mode × profile render composition: `"backend"` keyword substituted correctly in
  each slot for each profile kind; partial custom mode emits only defined slots.
- Default precedence: no `--mode` → `extreme`; no `--profile`/`--backend` →
  `default_profile`.
- Mutual exclusion: `--profile` + `--backend` → non-zero error.
- `profiles` subcommand output lists profiles + targets.
- setup multi-preset (stubbed `curl`): iterates fusion profiles, writes per-slug
  markers; `--profile NAME` scoping; alias profile → "nothing to set up".
- doctor profile-aware: stubbed in-sync vs drifted preset per profile; profiles
  summary present.
- shellcheck clean for all scripts (existing gate).

## Automated verification

- `make check` (deps) passes.
- `just all` (shellcheck + smoke) passes.

## Manual verification

- `./setup.sh --key-file ~/.config/smorin/.env` creates all fusion presets; markers
  written under `$CFL_STATE_DIR/presets/`.
- `bin/claude-fusion profiles` lists `fusion` (fusion), `deepseek`/`qwen` (model).
- `bin/claude-fusion --profile fusion --mode main --show-settings` → opus +
  subagent = `@preset/cc-fusion`.
- `bin/claude-fusion --profile deepseek --show-settings` → all slots =
  `deepseek/deepseek-v3.2` (extreme default).
- `bin/claude-fusion --backend "qwen/qwen3-coder-plus" --show-settings` → all slots
  = `qwen/qwen3-coder-plus`.
- `bin/claude-fusion --profile deepseek --backend foo` → error (mutually exclusive).
- **Foundational routing (already passed 2026-06-25):**
  `ANTHROPIC_BASE_URL=https://openrouter.ai/api ANTHROPIC_AUTH_TOKEN=$KEY claude --model "deepseek/deepseek-v3.2" -p "say hi" --output-format json`
  → `is_error:false`, `modelUsage` keyed by the deepseek slug.
- `bin/claude-fusion --profile deepseek -p "say hi" --output-format json` →
  `modelUsage` shows the deepseek slug end-to-end through the launcher.

## Docs / project tracking

- README: new "Profiles" section (the three flavors, the matrix, `--profile` /
  `--backend` / `profiles`), updated modes section (`backend` keyword), and a note
  on the marker re-run after upgrade.
- `PROJECTS.md`: add **Project P03: profiles + multi-model backends (v0.3.0)** with
  tasks/tests mirroring this spec.
