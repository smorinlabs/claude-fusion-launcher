# claude-fusion-launcher

Run **Claude Code** through **OpenRouter's [Fusion](https://openrouter.ai/docs/guides/routing/routers/fusion-router) router** — a multi-model panel that answers in parallel and is synthesized by a judge model — wired in as your main model, as a subagent "second opinion", or everywhere.

One-time setup creates your own OpenRouter preset (a custom 5-model panel); then a single launcher runs Claude Code with fusion wired in per a configurable **mode**, in both interactive and `claude -p` modes.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on your PATH)
- An [OpenRouter](https://openrouter.ai) API key (`sk-or-v1-...`)
- `curl` and `jq`

```bash
make check   # verifies claude, curl, jq
```

## Quickstart

```bash
# 1. One-time: create your OpenRouter "cc-fusion" preset (the custom 5-model panel)
./setup.sh --key-file ~/.config/openrouter.env     # or --key sk-or-v1-...  or  export OPENROUTER_API_KEY=...

# 2. Run Claude Code with fusion (default mode = fusion main + fusion subagents)
bin/claude-fusion -g                                # "just go" — default mode, interactive
bin/claude-fusion --mode subagent -p "design a rate limiter"   # a lighter mode, headless (-p)
```

Run `claude-fusion` with no arguments for help (and, on a terminal, a y/N prompt to just go). Install it onto your PATH with `make install` (or `just install`).

## Modes

Modes are defined in `config/modes.json` and are fully editable. Shipped defaults:

| mode | opus tier | sonnet tier | haiku tier | subagents | use it for |
|------|-----------|-------------|------------|-----------|------------|
| `main` *(default)* | **fusion** | Sonnet | Haiku | **fusion** | the default — fusion is your main model and your subagents |
| `subagent` | Opus | Sonnet | Haiku | **fusion** | lighter: Opus main, fusion only when a subagent is spawned |
| `extreme` | **fusion** | **fusion** | **fusion** | **fusion** | everything fusion (slowest/costliest) |

The literal `"fusion"` in any slot resolves to `@preset/<your-slug>` (or the configured `fallback` if you haven't run setup). Any other value is a literal model slug.

The shipped `config/modes.json.example` **is** the default — it works out of the box, no config file to create. To change anything, copy it once to `config/modes.json` (that override wins everywhere) and edit — e.g. add your own mode:

```bash
cp config/modes.json.example config/modes.json
```
```jsonc
// config/modes.json
"modes": {
  "myteam": { "default": "opus", "opus": "fusion", "sonnet": "deepseek/deepseek-v3.2", "haiku": "~anthropic/claude-haiku-latest", "subagent": "fusion" }
}
```
```bash
bin/claude-fusion --mode myteam -p "..."
```

Customize the panel itself (models + judge) in `config/modes.json` and re-run `./setup.sh`:

```json
"panel_models": ["~anthropic/claude-opus-latest","~openai/gpt-latest","~google/gemini-pro-latest","deepseek/deepseek-v3.2","qwen/qwen3-coder-plus"],
"judge_model": "~anthropic/claude-opus-latest"
```

## Providing your key (3 ways)

Precedence: **`--key` > `--key-file` > `$OPENROUTER_API_KEY`**.

```bash
bin/claude-fusion --key sk-or-v1-...             # 1. directly on the command line
bin/claude-fusion --key-file ~/.config/or.env    # 2. a file containing OPENROUTER_API_KEY=...
export OPENROUTER_API_KEY=sk-or-v1-...            # 3. environment variable
bin/claude-fusion
```

The key is injected only as `ANTHROPIC_AUTH_TOKEN` into the `claude` process (a subshell) — it is never written to disk or exported into your interactive shell. Key files are read by grep, not sourced.

## How it works (the research behind it)

Claude Code points at OpenRouter via `ANTHROPIC_BASE_URL=https://openrouter.ai/api`, `ANTHROPIC_AUTH_TOKEN=<key>`, `ANTHROPIC_API_KEY=""`. Fusion is reached through model slugs:

- **Fusion is a server tool, not a model.** `openrouter/fusion` runs a *default* 3-model panel. To run a *custom* panel you need an OpenRouter **preset** whose `config.model` is `openrouter/fusion` plus a `tools:[{type:"openrouter:fusion",parameters:{analysis_models:[…5…],model:<judge>}}]` block with `tool_choice:"required"`. `setup.sh` creates exactly that and references it as `@preset/<slug>`.
- **`@preset/` works on the Anthropic `/messages` endpoint** Claude Code uses, and **`CLAUDE_CODE_SUBAGENT_MODEL`** routes subagents to it — that's how the `subagent` mode gives you fusion as an on-demand second opinion.
- **The Claude Code `advisor` does *not* work through OpenRouter** (it's a server-side Anthropic tool). These profiles disable it (`CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`); use subagent/main fusion instead.
- **Presets are created only via** `POST /api/v1/presets/{slug}/chat/completions` (the direct `POST /api/v1/presets` returns 404).

## Commands

```bash
claude-fusion -g                     # launch the default mode (no other args needed)
claude-fusion --mode MODE [args…]    # launch a mode; extra args pass to claude (e.g. -p "…")
claude-fusion modes                  # list modes and their per-slot models
claude-fusion doctor                 # health check: deps, key, credits, preset, env conflicts
claude-fusion --show-settings        # print the resolved settings JSON, no launch (a.k.a. --dry-run)
claude-fusion --cost --mode … -p …   # run, then report the session's OpenRouter spend
claude-fusion --help                 # usage
```

Repo recipes (`make <t>` / `just <t>`): `check` (deps), `lint` (shellcheck), `test` (no-cost smoke),
`setup`, `install` (symlink onto PATH, `PREFIX` overridable), `hooks` (enable the gitleaks pre-commit hook).

### Startup connectivity check

Before launching Claude, the launcher runs a fast pre-flight (`lib/check-openrouter.sh`): if OpenRouter is unreachable or your key is rejected, it prints a one-line hint to run `claude-fusion doctor` — so you're not surprised by cryptic mid-session API errors. It's silent on success; disable it with `CFL_SKIP_PRECHECK=1`. (This is a launcher pre-flight rather than a Claude Code SessionStart hook because Claude Code does not execute hooks defined in a `--settings` file.)

## Cost & latency

Each fusion turn runs N panel models + a judge, so it costs and takes meaningfully more than a single model (panel turns observed ≈ **$0.15–0.35** each vs ~$0.01 for one Opus turn). The default `main` mode fuses every main turn; `subagent` is the cheapest (fusion only on subagent spawns); `extreme` is the most expensive. Keep prompts focused. `--cost` reports a session's actual spend (it waits briefly, with a countdown, for OpenRouter billing to settle).

## Troubleshooting

Run `claude-fusion doctor` first — it checks most of these and prints a fix for each. Common cases:

| Symptom | Likely cause / fix |
|---|---|
| `preset not set up — using fallback` | You haven't run `./setup.sh` (or you're on a different OpenRouter key/account). Run setup; `doctor` verifies the preset exists for the *current* key. |
| `OpenRouter rejected the key` | Key wrong/expired, or wrong `--key/--key-file`/`OPENROUTER_API_KEY`. |
| `insufficient credits` / fusion calls fail | Add credits at <https://openrouter.ai/settings/credits>; `doctor` shows your balance. |
| model-not-found errors | A panel slug in `config/modes.json` is invalid — check against <https://openrouter.ai/api/v1/models>. |
| Claude Code ignores the base URL / "model not found" for OpenRouter | A cached Anthropic login or a real `ANTHROPIC_API_KEY` in your shell can interfere. The launcher unsets `ANTHROPIC_API_KEY` per-run; if issues persist, `/logout` in Claude Code and unset the key (`doctor` warns if it's set). |
| `--cost` prints "no usage change detected" | OpenRouter billing lagged past the ~30s wait; check <https://openrouter.ai/activity>. |
| advisor never fires | Expected — the Claude Code advisor is a server-side Anthropic tool that doesn't work through OpenRouter; it's disabled in these profiles. Use `main`/`extreme` (fusion main) or `subagent` (fusion subagents) instead. |

## Development

```bash
just check   # deps        (make check)
just lint    # shellcheck
just test    # tests/smoke.sh — no API calls
```

CI (GitHub Actions) runs shellcheck, actionlint, and the no-cost smoke tests.

## License

MIT — see [LICENSE](LICENSE).
