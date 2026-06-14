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
