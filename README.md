# claude-fusion-launcher

**Run Claude Code on any OpenRouter backend — a fusion panel, a model alias, or a raw slug.**

This launcher points Claude Code at [OpenRouter](https://openrouter.ai) via **profiles**: use [OpenRouter Fusion](https://openrouter.ai/docs/guides/routing/routers/fusion-router) (several frontier models answering in parallel, merged by a judge), a named model alias, or any raw model slug. Same Claude Code you already use — sharper answers by routing through the backend that fits the job.

- **Drop-in.** One command launches Claude Code with your chosen backend wired in. No code changes.
- **Dial the power.** Any backend as your main model, as subagents only (a cheaper "second opinion"), or everywhere (`extreme` default).
- **Yours to configure.** Your OpenRouter key, your profiles, your modes.
- **Interactive or headless.** Works in normal sessions and in `claude -p` one-shots.

---

## Quick start

You need: **Claude Code** (`claude`), an **[OpenRouter](https://openrouter.ai) API key** (`sk-or-v1-…`), and **`curl`** + **`jq`**.

```bash
# 1. Get it
git clone https://github.com/smorinlabs/claude-fusion-launcher
cd claude-fusion-launcher

# 2. One-time setup — creates your fusion preset on your own OpenRouter account
./setup.sh --key-file ~/.config/openrouter.env     # or:  --key sk-or-v1-…   |   export OPENROUTER_API_KEY=…

# 3. Launch Claude Code with fusion
bin/claude-fusion -g                                # "just go" — default mode, interactive
bin/claude-fusion -p "design a rate limiter"        # headless one-shot
```

That's it. The default mode (`extreme`) runs the active profile's backend in every tier — main, Sonnet, Haiku, and subagents.

**Helpful extras:**
- `make install` — put `claude-fusion` on your PATH (then drop the `bin/`).
- `claude-fusion` with no arguments — prints help (and, in a terminal, offers to just go).
- `claude-fusion doctor` — checks your key, credits, preset, and environment if anything's off.

### Or use Flox (reproducible, zero manual installs)

[Flox](https://flox.dev) gives you Claude Code **and** every dependency — pinned — in one step, so there's nothing to install by hand:

```bash
flox activate          # first run fetches claude, curl, jq, shellcheck, just, gitleaks (pinned)
./setup.sh --key-file ~/.config/openrouter.env
claude-fusion -g       # already on your PATH inside the env
```

The environment is defined in `.flox/env/manifest.toml` — edit it and re-`flox activate` to change tools or versions.

---

## Modes

A **mode** decides where the active profile's backend is used. Pick one with `--mode`; the default is `extreme`.

| Mode | Main model | Subagents | Best for | Relative cost |
|------|-----------|-----------|----------|:---:|
| `main` | **backend** | **backend** | backend as your main model and in subagents | $$ |
| `subagent` | Opus | **backend** | cheaper day-to-day; backend only when Claude spawns a subagent | $ |
| `extreme` *(default)* | **backend** | **backend** | every tier (Opus/Sonnet/Haiku) + subagents on backend | $$$ |

```bash
bin/claude-fusion --mode subagent -p "explain this stack trace"
claude-fusion modes        # list modes and their exact per-slot models
```

### Customizing modes and the panel

Defaults ship in `config/modes.json.example` and work out of the box — **nothing to create**. To customize, copy it once (the copy wins everywhere) and edit:

```bash
cp config/modes.json.example config/modes.json
```

- **Add your own mode.** Each slot is a model slug, or the keyword `"backend"` (which resolves to the active profile's backend):
  ```jsonc
  "modes": {
    "myteam": { "default": "opus", "opus": "backend", "sonnet": "deepseek/deepseek-v3.2", "haiku": "~anthropic/claude-haiku-latest", "subagent": "backend" }
  }
  ```
  ```bash
  bin/claude-fusion --mode myteam -p "..."
  ```
- **Change the fusion panel itself** (which models deliberate + the judge), then re-run `./setup.sh`:
  ```jsonc
  "profiles": {
    "fusion": {
      "type": "fusion",
      "preset_slug": "cc-fusion",
      "panel_models": ["~anthropic/claude-opus-latest","~openai/gpt-latest","~google/gemini-pro-latest","deepseek/deepseek-v3.2","qwen/qwen3-coder-plus"],
      "judge_model": "~anthropic/claude-opus-latest",
      "fallback": "openrouter/fusion"
    }
  }
  ```

---

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

---

## Providing your key

Three ways, in precedence order **`--key` > `--key-file` > `$OPENROUTER_API_KEY`**:

```bash
bin/claude-fusion --key sk-or-v1-...             # 1. on the command line
bin/claude-fusion --key-file ~/.config/or.env    # 2. a file containing OPENROUTER_API_KEY=...
export OPENROUTER_API_KEY=sk-or-v1-... && bin/claude-fusion   # 3. environment variable
```

Your key is injected only as `ANTHROPIC_AUTH_TOKEN` into the `claude` process (in a subshell) — **never written to disk, never exported into your shell.** Key files are parsed with `sed`, not sourced.

---

## Commands

```bash
claude-fusion -g                              # launch the default mode (no other args needed)
claude-fusion --profile NAME [args…]          # use a named profile (fusion preset or model alias)
claude-fusion --backend "vendor/model" [args…]  # use a raw OpenRouter slug directly
claude-fusion --mode MODE [args…]             # launch a mode; extra args pass through to claude (e.g. -p "…")
claude-fusion modes                           # list modes and their per-slot models
claude-fusion profiles                        # list profiles and their targets
claude-fusion doctor                          # health check: deps, key, credits, preset, env conflicts
claude-fusion --show-settings                 # print the resolved settings JSON, no launch (alias: --dry-run)
claude-fusion --cost --mode … -p …            # run, then report what that session cost on OpenRouter
claude-fusion --help                          # usage
```

Repo tasks (run as `make <t>` or `just <t>`): `check` (verify deps) · `lint` (shellcheck) · `test` (no-cost smoke tests) · `setup` · `install` (symlink onto PATH; `PREFIX` overridable) · `hooks` (enable the gitleaks pre-commit hook). `just all` runs lint + tests.

### Startup connectivity check

Before launching Claude, the launcher runs a fast pre-flight: if OpenRouter is unreachable or your key is rejected, it prints a one-line hint to run `claude-fusion doctor` — so you aren't surprised by cryptic mid-session errors. Silent on success. Disable with `CFL_SKIP_PRECHECK=1`.

---

## Cost & latency

A fusion turn runs several models plus a judge, so it costs and takes more than a single model — observed roughly **$0.15–0.35 per fusion turn** vs ~$0.01 for one Opus turn. By mode: `subagent` is cheapest (backend only on subagent spawns), `main` routes every main turn through the backend, `extreme` is the most expensive. Keep prompts focused, and use `--cost` to see a session's actual spend (it waits briefly, with a countdown, for OpenRouter billing to settle).

---

## Troubleshooting

Run **`claude-fusion doctor`** first — it checks most of these and prints a fix for each.

| Symptom | Likely cause / fix |
|---|---|
| `preset not set up — using fallback` | You haven't run `./setup.sh` (or switched OpenRouter key/account). Run setup; `doctor` verifies the preset exists for the *current* key. |
| `OpenRouter rejected the key` | Key wrong/expired, or wrong `--key`/`--key-file`/`OPENROUTER_API_KEY`. |
| `insufficient credits` / fusion calls fail | Add credits at <https://openrouter.ai/settings/credits>; `doctor` shows your balance. |
| `model not found` errors | A panel slug in `config/modes.json` is invalid — check it against <https://openrouter.ai/api/v1/models>. |
| Claude Code ignores the base URL / "model not found" | A cached Anthropic login or a real `ANTHROPIC_API_KEY` in your shell can interfere. The launcher unsets it per-run; if it persists, `/logout` in Claude Code and unset the key (`doctor` warns if it's set). |
| `--cost` says "no usage change detected" | OpenRouter billing lagged past the ~30s wait; check <https://openrouter.ai/activity>. |
| The advisor never fires | Expected — Claude Code's advisor is a server-side Anthropic tool that doesn't work through OpenRouter (it's disabled here). Use `main`/`extreme` (backend as main) or `subagent` (backend in subagents) instead. |

---

## How it works

Claude Code is pointed at OpenRouter via `ANTHROPIC_BASE_URL=https://openrouter.ai/api`, `ANTHROPIC_AUTH_TOKEN=<key>`, `ANTHROPIC_API_KEY=""`. Fusion is reached through model slugs:

- **Fusion is a server tool, not a model.** `openrouter/fusion` runs a *default* 3-model panel. To run a *custom* panel you need an OpenRouter **preset** whose `config.model` is `openrouter/fusion` plus a `tools:[{type:"openrouter:fusion",parameters:{analysis_models:[…],model:<judge>}}]` block with `tool_choice:"required"`. `setup.sh` creates exactly that and the launcher references it as `@preset/<slug>`.
- **`@preset/` works on the Anthropic `/messages` endpoint** Claude Code uses, and **`CLAUDE_CODE_SUBAGENT_MODEL`** routes subagents to it — that's how `subagent` mode gives you fusion as an on-demand second opinion.
- **The Claude Code advisor doesn't work through OpenRouter** (server-side Anthropic tool); it's disabled via `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`. Fusion reaches you through the main tier and/or subagents instead.
- **Presets are created only via** `POST /api/v1/presets/{slug}/chat/completions` (the direct `POST /api/v1/presets` returns 404).

The connectivity warning is a launcher pre-flight, not a SessionStart hook: such a hook *does* execute, but Claude Code currently **discards SessionStart hook output** on new sessions ([anthropics/claude-code#10373](https://github.com/anthropics/claude-code/issues/10373)), so it can't show you the warning. A pre-flight prints reliably.

---

## Development

```bash
make check     # verify deps (claude, curl, jq)
just all       # shellcheck + no-cost smoke tests  (or: just lint / just test)
```

CI (GitHub Actions) runs shellcheck, actionlint, and the no-cost smoke tests on every push. A gitleaks pre-commit hook is available via `make hooks`.

## License

MIT — see [LICENSE](LICENSE).
