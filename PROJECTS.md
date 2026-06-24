## [x] Project P01: claude-fusion-launcher (v0.1.0)
**Goal/Requirement**: A team-usable, standalone toolkit to run Claude Code through OpenRouter's
Fusion multi-model panel, with a one-time per-user preset setup and a single configurable launcher.

- Setup script creates each user's own `cc-fusion` OpenRouter preset (custom 5-model panel), with a
  fallback to `openrouter/fusion` if not run.
- One launcher (`bin/claude-fusion`) with config-driven `--mode` (subagent / main / extreme + custom),
  working in interactive and `claude -p` modes.
- Three key-input methods: `--key`, `--key-file`, `$OPENROUTER_API_KEY` (in that precedence).

**Out of Scope**
- Native-Anthropic advisor (server-side tool; does not work through OpenRouter — disabled).
- Committing secrets (public repo).

### Tests & Tasks
- [x] [P01-T01] `lib/common.sh`: key resolution (3 methods), config load, fusion-ref, settings render
- [x] [P01-T02] `setup.sh`: create + verify the `cc-fusion` preset; write PRESET_READY marker
- [x] [P01-T03] `bin/claude-fusion`: `--mode`, key methods, subshell-scoped secret, arg passthrough
- [x] [P01-T04] `config/modes.json.example`: subagent / main / extreme with per-slot models
- [x] [P01-TS01] `tests/smoke.sh`: shellcheck, mode render, fusion-keyword resolution, key precedence
- [x] [P01-T05] Scaffolding: README, justfile, Makefile, CI (shellcheck/actionlint/smoke), LICENSE
- [ ] [P01-TS02] Live verification: setup creates preset; each mode routes correctly via `claude -p`

### Automated Verification
- `make check` (deps), `just lint` (shellcheck), `just test` (`tests/smoke.sh`) all pass.

### Manual Verification
- `./setup.sh --key-file ~/.config/smorin/.env` creates the preset.
- `bin/claude-fusion --mode main -p "say hi" --output-format json` → `modelUsage` shows `@preset/cc-fusion`.
- `bin/claude-fusion --mode subagent -p "<spawns a subagent>"` → main Opus + subagent fusion.

---

## [x] Project P02: doctor preset transparency (v0.2.0)
**Goal/Requirement**: `doctor` should show the live preset's full configuration (panel models,
judge, tool_choice) and flag drift from the config it was built from, plus confirm which key it
actually resolved.

- Display live `analysis_models`, judge, and `tool_choice` from the preset (reuse the response
  doctor already fetches — no extra API call).
- Compare panel + judge against config `.panel_models` / `.judge_model`; on mismatch emit a
  non-fatal `⚠ differs — re-run ./setup.sh` (doctor still exits 0).
- Print the resolved key's last-4 (locally derived) to confirm which key/env was picked up.

**Out of Scope**
- Changing doctor's exit-code semantics for existing checks; comparing against a hardcoded
  baseline (we diff against the user's own config).

### Tests & Tasks
- [x] [P02-TS01] `tests/smoke.sh` #20: in-sync stub asserts panel/judge lines + "in sync";
      drifted stub asserts "differs" and exit 0; assert key last-4 + source lines present
- [x] [P02-T01] `cfl_doctor`: print resolved-key last-4 + source (file path / env var / --key flag)
- [x] [P02-T02] `cfl_doctor`: display live panel/judge/tool_choice from existing `pinfo`
- [x] [P02-T03] `cfl_doctor`: diff panel+judge vs config, warn (non-fatal) on drift

### Automated Verification
- `make check`, then `just all` (shellcheck + smoke) pass.

### Manual Verification
- `bin/claude-fusion doctor --key-file ~/.config/smorin/.env` shows panel/judge/tool_choice,
  a "matches config" line, and the key last-4.
