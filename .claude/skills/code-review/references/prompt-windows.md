# Windows Reviewer Prompt

```
You are reviewing the Windows platform folder of the claude-status-line project — a custom
status line for Claude Code that parses JSON from stdin and renders ANSI output.

Review these files in windows/:
  {FILES}

{DIFF_CONTEXT}

The Windows scripts are functionally equivalent to macOS/Linux but use PowerShell 5.1 idioms:
- JSON parsing via ConvertFrom-Json (returns PSCustomObject, not hashtable)
- Date handling via [DateTimeOffset]
- Notifications via BurntToast module
- File I/O must handle UTF-8 without BOM (PS 5.1 defaults to UTF-16 LE)

## Project rules (from CLAUDE.md)

These are the project's non-negotiable invariants:
- **Silent degradation**: Every script MUST exit 0, even on error. Never write to stderr.
  Breaking this crashes the Claude Code status line for users.
- **File encoding**: .ps1 files must use CRLF line endings with UTF-8 BOM (enforced by
  .gitattributes). When writing config files (settings.json, etc.), use explicit UTF-8
  no-BOM encoding — PS 5.1 defaults to UTF-16 LE which breaks other tools.
- **Naming conventions**: PowerShell functions use PascalCase.
- **Robustness**: Scripts must exit 0 on empty, malformed, or missing JSON input.
- **Debug logging**: Errors go to ~/.claude/statusline-debug.log only when
  $env:STATUSLINE_DEBUG is set. Never to the terminal.
- **Git edge cases**: Git status row must handle detached HEAD, no-repo, and fresh-clone.
- **Scope discipline**: Don't flag code just because it could be refactored or made more
  "elegant" — only flag actual bugs, convention violations, or correctness issues.

## Severity definitions

- **critical**: Breaks functionality or violates the silent degradation contract (exit
  non-zero, stderr output, crash). Must be fixed before shipping.
- **warning**: Incorrect behavior possible under certain conditions — edge cases, race
  conditions, missing null checks.
- **nit**: Style or convention issue that doesn't affect behavior.

## Deterministic check results (already verified — do not re-report)

The following checks were run by a deterministic script before your review. Items marked
"passed" are confirmed correct — skip them. Items marked "failed" are already captured —
do not duplicate them in your findings.

{DETERMINISTIC_RESULTS}

## Suppressed findings (do not report)

These finding slugs have been previously reviewed and dismissed by the user. Do not report
findings matching these slugs: {SUPPRESSED_SLUGS}

## What to check

### 1. Silent degradation (CRITICAL)
- Every script MUST exit 0. Use try/catch blocks, not unhandled exceptions.
- No output to stderr. Suppress errors with -ErrorAction SilentlyContinue or try/catch.
- Debug logging only when $env:STATUSLINE_DEBUG is set.

### 2. ANSI rendering correctness (statusline.ps1)
- Box characters must align. Write-Host -NoNewline used for inline output.
- Color thresholds: green/yellow/red transitions must match macOS/Linux behavior.
- ANSI escape sequences must work in Windows Terminal and PS 5.1.
- No trailing whitespace or misaligned box edges.

### 3. PowerShell conventions
- Functions: PascalCase (e.g., Get-GitStatus, Format-ContextBar).
- PS 5.1-compatible syntax only — no ternary (?:), no null-coalescing (??),
  no null-conditional (?.).
- ConvertFrom-Json returns PSCustomObject — property access must handle missing properties
  with $null checks, not hashtable indexing.

### 4. File encoding (CRITICAL)
- .ps1 files must be CRLF with UTF-8 BOM (enforced by .gitattributes).
- When writing files (install.ps1), use explicit UTF-8 no-BOM encoding for settings.json
  and other config files. PS 5.1's default is UTF-16 LE which breaks other tools.

### 5. JSON parsing correctness (statusline.ps1)
- All fields from the JSON input contract must be handled.
- Must exit 0 on empty, malformed, or missing JSON input.
- PSCustomObject property access must not throw on missing nested properties.
- Null/empty handling for every extracted field.
- Field paths must match the documented contract: session_id, workspace.current_dir, cwd,
  model.display_name, context_window.context_window_size, context_window.used_percentage,
  context_window.total_input_tokens, effort.level, cost.total_cost_usd, transcript_path,
  rate_limits.five_hour.*, rate_limits.seven_day.*, agent.name,
  context_window.current_usage.*

### 6. Caching logic (statusline.ps1)
- Output cache keyed by hashing JSON + file modification times.
- Git status cache uses a 5-second TTL. Verify the TTL check is correct.
- Cache files cleaned up properly on invalidation.

### 7. Installer correctness (install.ps1)
- BurntToast module check and optional install.
- Copy-WithRetry helper for locked files.
- settings.json merging must preserve existing user settings.
- Hook registration must be idempotent.
- Format-Json workaround for PS 5.1's broken ConvertTo-Json indentation.

### 8. Uninstaller correctness (uninstall.ps1)
- Removes the statusline script, settings.json entries, hooks, notification config, and
  temp/cache files.
- Must not fail if artifacts are already missing (idempotent removal).
- Must not clobber unrelated user settings — only remove entries the installer added.
- Should offer confirmation or dry-run where destructive.
- Silent degradation: no stderr, exit 0. Use try/catch and -ErrorAction.

### 9. Notification handler (notify.ps1)
- BurntToast integration for visual notifications.
- System.Media.SoundPlayer for sound with correct Windows Media sound paths.
- Permission event stdin parsing via [Console]::In.ReadToEnd().
- Per-event config from notify-config.json.

### 10. git-refresh hook (git-refresh.ps1)
- Reads event JSON from stdin, filters by tool name.
- Removes correct cache files. Must not fail if files don't exist.

### 11. Logic edge cases (all scripts)
Beyond convention checks, look for logic bugs: arithmetic that overflows or truncates
incorrectly, missing branches in switch statements, null-handling in numeric contexts,
cache keys that could collide. Don't go as deep as the logic auditor — flag only issues you
notice while checking your other categories.

### 12. Edge-case input handling (statusline.ps1)
The statusline receives arbitrary JSON from Claude Code. Verify it handles gracefully:
- All fields missing (empty `{}`)
- Fields present but $null or empty string
- Extreme values: 100% context usage, $9999 cost, 999999999 tokens
- Non-numeric values where numbers are expected
- Very long strings (200-character branch names, deep paths)

### 13. Runtime verification
{RUNTIME_VERIFICATION}

## Output format

Return a structured list of findings. For each issue:
- **File**: specific file and line number (e.g., statusline.ps1:247)
- **Slug**: a short kebab-case canonical identifier for the bug (e.g., missing-exit-0,
  start-process-nonewwindow-leak). Same bug must always get the same slug across runs.
- **Severity**: critical / warning / nit (see severity definitions above)
- **Description**: what's wrong and why it matters
- **Suggested fix**: concrete code change

If a file has no issues, say so explicitly — "no issues found" is a valid and useful result.
Only report issues you are confident about. Do not speculate or pad the list.
```

## Runtime verification — full

Don't rely solely on reading code. Where feasible, verify findings against actual behavior:
- Pipe empty JSON through statusline:
  '{}' | powershell -File windows\statusline.ps1 — should exit 0, no stderr.
- Test notify: powershell -File windows\notify.ps1 stop — should exit 0, no stderr.
- Test git-refresh:
  '{"tool_name":"Write"}' | powershell -File windows\git-refresh.ps1
- For install/uninstall, read to understand behavior without running destructively.
Flag which findings you verified at runtime vs. static analysis only.

## Runtime verification — static

Runtime verification is unavailable (host OS does not support this platform's scripts). All findings
are static analysis only. Append `[static]` to each finding's description to indicate no runtime
verification was performed.
