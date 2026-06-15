# Bug Report

Findings from a bug sweep of `claude-fusion-launcher`. Sorted by severity, then validity.

---

## BUG-01: `cfl_doctor` aborts mid-report when `curl` is missing (set -e + `&&`-terminated helper)

| Field | Value |
|---|---|
| **Severity** | high |
| **Bug Type** | logic / error-handling |
| **Validity** | definite |
| **File** | `lib/common.sh:123` (helper), triggered at `lib/common.sh:143` |
| **Verdict** | FIX |

**Description**: The `_d_warn` helper ends with `[ -n "${2:-}" ] && printf ...`. When called with a **single argument** (no hint), the `[ -n "" ]` test returns 1, the `&&` short-circuits, and the function returns 1. Because `bin/claude-fusion` runs under `set -euo pipefail`, this nonzero return aborts the whole `doctor` run.

The only single-argument `_d_warn` call is line 143:
```bash
elif ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  _d_warn "curl/jq needed for account checks"   # <-- single arg → returns 1 → set -e aborts
```

**Why it's a bug**: `doctor` is the tool for diagnosing a broken environment. `cfl_require jq` (bin/claude-fusion:53) guarantees `jq` is present, but **`curl` is not required** for doctor. So on a machine where `curl` is missing and a key is available, the flow reaches line 143, `_d_warn` returns 1, and `set -e` kills the process *immediately* — the `--- claude code env ---` section and the final `doctor: ...` summary never print, and doctor exits 1 abruptly rather than completing its report. Reproduced end-to-end:

```
--- key & account ---
  warn curl/jq needed for account checks
OUTER script rc=1          # "claude code env" + summary never printed
```

**Why it might NOT be a bug**: The trigger requires `curl` missing while a key is resolvable — an uncommon combination, and `_d_no` at line 129 will already have flagged curl as missing (so `rc=1` regardless). The user still sees *a* curl error. But the report is silently truncated, which is precisely the failure mode a diagnostic tool must avoid.

**Suggested fix**: Make the helpers' final statement unconditionally succeed, matching the already-safe `_d_no` (which ends with `rc=1`, returning 0). Two clean options:

```bash
# Option A: terminate with a no-op true
_d_warn() { printf '  \xe2\x9a\xa0 %s\n' "$1"; [ -n "${2:-}" ] && printf '      \xe2\x86\xb3 %s\n' "$2"; return 0; }
```
```bash
# Option B: use an if instead of &&
_d_warn() {
  printf '  \xe2\x9a\xa0 %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '      \xe2\x86\xb3 %s\n' "$2"; fi
}
```
Note `_d_ok` is already safe (single `printf`, returns 0) and `_d_no` is safe (ends in `rc=1` assignment, returns 0). Only `_d_warn` needs the fix.

---

## BUG-02: README says key files are read "by grep" but code uses `sed`

| Field | Value |
|---|---|
| **Severity** | low |
| **Bug Type** | consistency |
| **File** | `README.md:75` vs `lib/common.sh:42` |
| **Verdict** | FIX (trivial doc correction) |

**Description**: README:75 states *"Key files are read by grep, not sourced."* The actual implementation (`cfl_resolve_key`, common.sh:42) uses `sed -nE`, not `grep`.

**Why it's a bug**: Documentation/code divergence. The security claim it's making (*read, not sourced*) is correct and important — only the tool name is wrong, which could mislead a reader auditing the security behavior.

**Why it might NOT be a bug**: Purely cosmetic; the substantive security guarantee (no sourcing → no env pollution / code execution from the key file) holds. The smoke test at line 83-85 confirms the parse works.

**Suggested fix**: Change "read by grep, not sourced" → "parsed with `sed`, not sourced" (or just "parsed, not sourced").

---

## Summary

**By severity**: high 1 · low 1
**By type**: logic/error-handling 1 · consistency 1

**Recommended fix order**:
1. **BUG-01** (high) — one-line fix to `_d_warn`; restores doctor's ability to complete its report when a dependency is missing.
2. **BUG-02** (low) — one-word doc correction in README.

**Overall code health**: Strong for a shell project — `set -euo pipefail` throughout, symlink-resolved `$0`, careful array expansion (`${args[@]+"${args[@]}"}`), key never written to disk, and a genuinely good no-cost smoke suite covering partial-mode null omission, key precedence, and symlink/cwd invocation. The single real defect is the classic `&&`-terminated-helper-under-`set -e` footgun in the one code path the smoke tests don't exercise (missing `curl`).
