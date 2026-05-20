---
name: code-review
description: >
  Multi-platform code review for claude-status-line with three scope modes: full project
  (3 OS agents + parity checker), single-platform deep dive (one agent per file), or
  script-type review across platforms. Discovers files dynamically via Glob — never goes stale.
  Trigger on: "review", "code review", "audit", "check parity", "check all platforms",
  or any request to find bugs across the repo.
---

# Code Review — claude-status-line

This skill runs a structured, parallel code review with dynamic file discovery and three scope modes.

## Phase 0 — Scope detection and file discovery

### Step 1: Detect scope

Parse the user's request to determine the review mode:

| Mode | Trigger | Dispatch |
|------|---------|----------|
| **Full** (default) | No qualifier, or "review everything" | 3 OS agents + 1 parity checker |
| **Platform** | Names a specific OS — "review macos/", "check windows scripts" | 1 agent per file in that folder |
| **Script-type** | Names a script type — "review installers", "check notify handlers" | 3 OS agents (scoped) + 1 parity checker |

Script-type keyword → file pattern:

| Keyword | Pattern |
|---------|---------|
| "statusline" | `statusline.*` |
| "installer" / "install" | `install.*` |
| "uninstaller" / "uninstall" | `uninstall.*` |
| "notify" / "notification" | `notify.*` |
| "git-refresh" / "hook" | `git-refresh.*` |

### Step 2: Discover files

Run Glob **before dispatching** to build the file inventory dynamically:

- `Glob("macos/*.sh")` — macOS scripts
- `Glob("linux/*.sh")` — Linux scripts
- `Glob("windows/*.ps1")` — Windows scripts

For **script-type mode**, filter the results to only files matching the detected pattern.

### Step 3: Dispatch

Launch all subagents in a **single message** for concurrency. Use `subagent_type: "feature-dev:code-reviewer"` for all agents.

**Full mode** — 4 agents:

| Agent | Prompt | `{FILES}` value |
|-------|--------|-----------------|
| macOS reviewer | macOS prompt below | All discovered `macos/` files |
| Linux reviewer | Linux prompt below | All discovered `linux/` files |
| Windows reviewer | Windows prompt below | All discovered `windows/` files |
| Parity checker | Parity prompt below | All files, grouped by script type |

**Platform mode** — one agent per file:

Dispatch one agent per discovered file in the target folder. Use the same OS prompt template as full mode, but set `{FILES}` to the single file name. The subagent will focus on the check categories relevant to that file type (each category heading indicates which file it applies to). No parity checker in platform mode.

**Script-type mode** — 4 agents (scoped):

Same dispatch as full mode, but `{FILES}` contains only the file(s) matching the script-type pattern per platform. The parity checker's `{ALL_FILES}` is similarly filtered.

### Placeholder substitution

Before sending each prompt, replace these placeholders with actual values:

- `{FILES}` — comma-separated file names from Glob (e.g., `statusline.sh, install.sh, notify.sh`)
- `{ALL_FILES}` — all files grouped by script type across platforms, one group per line. Match files across platforms by base name (e.g., `statusline`). Format:
  `macos/statusline.sh, linux/statusline.sh, windows/statusline.ps1`
  `macos/install.sh, linux/install.sh, windows/install.ps1`
  ...etc for each discovered script type.

After all agents return, proceed to Phase 1 (synthesis).

### Invocation examples

```
# Full (default) — 3 OS agents + parity checker
/code-review

# Platform — one agent per file in the target folder
/code-review of macos scripts

# Script-type — 3 scoped OS agents + parity checker
/code-review of all installer scripts
```

## Subagent prompt templates

### Prompt: macOS reviewer

```
You are reviewing the macOS platform folder of the claude-status-line project — a custom
status line for Claude Code that parses JSON from stdin and renders ANSI output.

Review these files in macos/:
  {FILES}

## Project rules (from CLAUDE.md)

These are the project's non-negotiable invariants:
- **Silent degradation**: Every script MUST exit 0, even on error. Never write to stderr.
  Breaking this crashes the Claude Code status line for users.
- **File encoding**: .sh files must use LF line endings (enforced by .gitattributes).
- **Naming conventions**: Bash functions use snake_case. Constants use UPPER_CASE.
- **Robustness**: Scripts must exit 0 on empty, malformed, or missing JSON input.
- **Debug logging**: Errors go to ~/.claude/statusline-debug.log only when STATUSLINE_DEBUG
  is set. Never to the terminal.
- **Git edge cases**: Git status row must handle detached HEAD, no-repo, and fresh-clone.
- **Scope discipline**: Don't flag code just because it could be refactored or made more
  "elegant" — only flag actual bugs, convention violations, or correctness issues.

## Severity definitions

- **critical**: Breaks functionality or violates the silent degradation contract (exit
  non-zero, stderr output, crash). Must be fixed before shipping.
- **warning**: Incorrect behavior possible under certain conditions — edge cases, race
  conditions, missing null checks.
- **nit**: Style or convention issue that doesn't affect behavior.

## What to check

### 1. Silent degradation (CRITICAL)
- Every script MUST exit 0, even on error. A non-zero exit or stderr output crashes the
  Claude Code status line for users.
- No output to stderr anywhere. Redirect errors with 2>/dev/null.
- Errors go to the debug log only when STATUSLINE_DEBUG is set.

### 2. ANSI rendering correctness (statusline.sh)
- Box characters must align — no trailing whitespace or off-by-one in padding.
- Color thresholds: green/yellow/red transitions for context usage, rate limits, cost.
- Reset sequences (\033[0m) after every colored span to prevent bleed.
- The output must render correctly in terminals with different widths.

### 3. Bash conventions
- Functions: snake_case. Constants: UPPER_CASE. No exceptions.
- Bash 4+ features only (mapfile, associative arrays). The shebang uses /usr/bin/env bash,
  expecting Homebrew bash — not macOS default /bin/bash which is 3.2.
- Quote all variable expansions unless intentionally word-splitting.
- Use [[ ]] not [ ] for conditionals.

### 4. macOS-specific correctness
- stat uses -f (BSD), not -c (GNU).
- Dependencies: jq (required), terminal-notifier (optional, for visual notifications).
- Sound dispatch via afplay with /System/Library/Sounds/ paths.
- Visual dispatch via terminal-notifier.

### 5. JSON parsing correctness (statusline.sh)
- All fields extracted via jq in the mapfile block must handle missing/null values gracefully.
- Must exit 0 on empty, malformed, or missing JSON input.
- Field paths must match the documented contract: session_id, workspace.current_dir, cwd,
  model.display_name, context_window.context_window_size, context_window.used_percentage,
  context_window.total_input_tokens, effort.level, cost.total_cost_usd, transcript_path,
  rate_limits.five_hour.*, rate_limits.seven_day.*, agent.name,
  context_window.current_usage.*

### 6. Caching logic (statusline.sh)
- Output cache keyed by hashing JSON + file modification times.
- Git status cache uses a 5-second TTL. Verify the TTL check is correct.
- Cache files cleaned up properly on invalidation.

### 7. Installer correctness (install.sh)
- Dependency checks (jq, terminal-notifier) with install offers.
- settings.json merging must not clobber existing user settings.
- Hook registration (git-refresh, notify) must be idempotent — re-running the installer
  should not duplicate entries.

### 8. Uninstaller correctness (uninstall.sh)
- Removes the statusline script, settings.json entries, hooks, notification config, and
  temp/cache files.
- Must not fail if artifacts are already missing (idempotent removal).
- Must not clobber unrelated user settings — only remove entries the installer added.
- Should offer confirmation or dry-run where destructive.
- Silent degradation applies here too — no stderr, exit 0.

### 9. Notification handler (notify.sh)
- Per-event config loading from notify-config.json.
- Sound dispatch via afplay with correct system sound paths.
- Visual dispatch via terminal-notifier with proper escaping.
- Permission event: parses stdin JSON for tool_name and tool_input detail.

### 10. git-refresh hook (git-refresh.sh)
- Reads event JSON from stdin, filters by tool name.
- Removes correct cache files (git cache + output cache).
- Must not break if cache files don't exist.

### 11. Runtime verification
Don't rely solely on reading code. Where feasible, verify findings against actual behavior:
- Pipe empty JSON through statusline: echo '{}' | bash macos/statusline.sh — should exit 0
  with no stderr.
- Test notify: echo '' | bash macos/notify.sh stop — should exit 0, no stderr.
- Test git-refresh: echo '{"tool_name":"Write"}' | bash macos/git-refresh.sh
- For install/uninstall, read to understand behavior without running destructively.
Flag which findings you verified at runtime vs. static analysis only.

## Output format

Return a structured list of findings. For each issue:
- **File**: specific file and line number (e.g., statusline.sh:247)
- **Severity**: critical / warning / nit (see severity definitions above)
- **Description**: what's wrong and why it matters
- **Suggested fix**: concrete code change

If a file has no issues, say so explicitly — "no issues found" is a valid and useful result.
Only report issues you are confident about. Do not speculate or pad the list.
```

### Prompt: Linux reviewer

```
You are reviewing the Linux platform folder of the claude-status-line project — a custom
status line for Claude Code that parses JSON from stdin and renders ANSI output.

Review these files in linux/:
  {FILES}

The Linux scripts are ~95% identical to macOS. Key known differences:
- stat uses -c (GNU coreutils) instead of -f (BSD) for file metadata
- Notification sound uses paplay/aplay instead of afplay
- Notification visual uses notify-send instead of terminal-notifier
- Package manager detection differs (apt, dnf, pacman, zypper vs. brew)

## Project rules (from CLAUDE.md)

These are the project's non-negotiable invariants:
- **Silent degradation**: Every script MUST exit 0, even on error. Never write to stderr.
  Breaking this crashes the Claude Code status line for users.
- **File encoding**: .sh files must use LF line endings (enforced by .gitattributes).
- **Naming conventions**: Bash functions use snake_case. Constants use UPPER_CASE.
- **Robustness**: Scripts must exit 0 on empty, malformed, or missing JSON input.
- **Debug logging**: Errors go to ~/.claude/statusline-debug.log only when STATUSLINE_DEBUG
  is set. Never to the terminal.
- **Git edge cases**: Git status row must handle detached HEAD, no-repo, and fresh-clone.
- **Scope discipline**: Don't flag code just because it could be refactored or made more
  "elegant" — only flag actual bugs, convention violations, or correctness issues.

## Severity definitions

- **critical**: Breaks functionality or violates the silent degradation contract (exit
  non-zero, stderr output, crash). Must be fixed before shipping.
- **warning**: Incorrect behavior possible under certain conditions — edge cases, race
  conditions, missing null checks.
- **nit**: Style or convention issue that doesn't affect behavior.

## What to check

### 1. Silent degradation (CRITICAL)
- Every script MUST exit 0, even on error. A non-zero exit or stderr output crashes the
  Claude Code status line for users.
- No output to stderr anywhere. Redirect errors with 2>/dev/null.
- Errors go to the debug log only when STATUSLINE_DEBUG is set.

### 2. ANSI rendering correctness (statusline.sh)
- Box characters must align — no trailing whitespace or off-by-one in padding.
- Color thresholds: green/yellow/red transitions for context usage, rate limits, cost.
- Reset sequences (\033[0m) after every colored span to prevent bleed.
- The output must render correctly in terminals with different widths.

### 3. Bash conventions
- Functions: snake_case. Constants: UPPER_CASE. No exceptions.
- Bash 4+ required (mapfile, associative arrays). Linux distros generally ship Bash 4+.
- Quote all variable expansions unless intentionally word-splitting.
- Use [[ ]] not [ ] for conditionals.

### 4. Linux-specific correctness
- stat uses -c (GNU coreutils), not -f (BSD).
- Sound dispatch via paplay/aplay — not macOS afplay.
- Visual dispatch via notify-send — not macOS terminal-notifier.
- Package manager detection must handle apt, dnf, pacman, zypper gracefully.
- No macOS-isms left over from copy-paste (afplay, terminal-notifier, brew,
  /System/Library/Sounds/, etc.).

### 5. JSON parsing correctness (statusline.sh)
- All fields extracted via jq in the mapfile block must handle missing/null values gracefully.
- Must exit 0 on empty, malformed, or missing JSON input.
- Field paths must match the documented contract: session_id, workspace.current_dir, cwd,
  model.display_name, context_window.context_window_size, context_window.used_percentage,
  context_window.total_input_tokens, effort.level, cost.total_cost_usd, transcript_path,
  rate_limits.five_hour.*, rate_limits.seven_day.*, agent.name,
  context_window.current_usage.*

### 6. Caching logic (statusline.sh)
- Output cache keyed by hashing JSON + file modification times.
- Git status cache uses a 5-second TTL. Verify the TTL check is correct.
- Cache files cleaned up properly on invalidation.

### 7. Installer correctness (install.sh)
- Dependency checks (jq, and optionally notify-send) with install offers.
- settings.json merging must not clobber existing user settings.
- Hook registration (git-refresh, notify) must be idempotent — re-running the installer
  should not duplicate entries.

### 8. Uninstaller correctness (uninstall.sh)
- Removes the statusline script, settings.json entries, hooks, notification config, and
  temp/cache files.
- Must not fail if artifacts are already missing (idempotent removal).
- Must not clobber unrelated user settings — only remove entries the installer added.
- Should offer confirmation or dry-run where destructive.
- Silent degradation applies here too — no stderr, exit 0.

### 9. Notification handler (notify.sh)
- Per-event config loading from notify-config.json.
- Sound dispatch via paplay/aplay with correct Linux sound paths.
- Visual dispatch via notify-send with proper escaping.
- Permission event: parses stdin JSON for tool_name and tool_input detail.

### 10. git-refresh hook (git-refresh.sh)
- Reads event JSON from stdin, filters by tool name.
- Removes correct cache files (git cache + output cache).
- Must not break if cache files don't exist.

### 11. Runtime verification
Don't rely solely on reading code. Where feasible, verify findings against actual behavior:
- Pipe empty JSON through statusline: echo '{}' | bash linux/statusline.sh — should exit 0
  with no stderr.
- Test notify: echo '' | bash linux/notify.sh stop — should exit 0, no stderr.
- Test git-refresh: echo '{"tool_name":"Write"}' | bash linux/git-refresh.sh
- For install/uninstall, read to understand behavior without running destructively.
Flag which findings you verified at runtime vs. static analysis only.

## Output format

Return a structured list of findings. For each issue:
- **File**: specific file and line number (e.g., statusline.sh:247)
- **Severity**: critical / warning / nit (see severity definitions above)
- **Description**: what's wrong and why it matters
- **Suggested fix**: concrete code change

If a file has no issues, say so explicitly — "no issues found" is a valid and useful result.
Only report issues you are confident about. Do not speculate or pad the list.
```

### Prompt: Windows reviewer

```
You are reviewing the Windows platform folder of the claude-status-line project — a custom
status line for Claude Code that parses JSON from stdin and renders ANSI output.

Review these files in windows/:
  {FILES}

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

### 11. Runtime verification
Don't rely solely on reading code. Where feasible, verify findings against actual behavior:
- Pipe empty JSON through statusline:
  '{}' | powershell -File windows\statusline.ps1 — should exit 0, no stderr.
- Test notify: powershell -File windows\notify.ps1 stop — should exit 0, no stderr.
- Test git-refresh:
  '{"tool_name":"Write"}' | powershell -File windows\git-refresh.ps1
- For install/uninstall, read to understand behavior without running destructively.
Flag which findings you verified at runtime vs. static analysis only.

## Output format

Return a structured list of findings. For each issue:
- **File**: specific file and line number (e.g., statusline.ps1:247)
- **Severity**: critical / warning / nit (see severity definitions above)
- **Description**: what's wrong and why it matters
- **Suggested fix**: concrete code change

If a file has no issues, say so explicitly — "no issues found" is a valid and useful result.
Only report issues you are confident about. Do not speculate or pad the list.
```

### Prompt: Cross-platform parity checker

```
You are the cross-platform parity checker for the claude-status-line project. Your job is to
diff behavior across all three platforms (macos/, linux/, windows/) and find drift — features,
fixes, or behaviors present on one platform but missing or different on another.

Read ALL of these files:
  {ALL_FILES}

## Project rules (from CLAUDE.md)

- **Cross-platform parity**: Changes to one platform almost always require matching changes
  on the others. macOS and Linux share Bash — keep them in sync. Windows PowerShell is
  functionally equivalent using PS idioms.
- **Silent degradation**: Every script MUST exit 0, even on error. Never write to stderr.
- **File encoding**: .sh = LF line endings. .ps1 = CRLF + UTF-8 BOM.
- **Naming**: Bash uses snake_case functions + UPPER_CASE constants. PowerShell uses PascalCase.

## Severity definitions

- **critical**: Breaks functionality or violates the silent degradation contract.
- **warning**: Incorrect behavior possible under certain conditions.
- **nit**: Style or convention issue that doesn't affect behavior.

## Architecture context

- macOS and Linux are both Bash and should be ~95% identical. The ONLY expected differences:
  - stat flags: macOS uses -f, Linux uses -c
  - Sound: macOS=afplay, Linux=paplay/aplay
  - Visual notifications: macOS=terminal-notifier, Linux=notify-send
  - Package managers: macOS=brew, Linux=apt/dnf/pacman/zypper
  - Anything else that differs between macOS and Linux is likely a bug (drift).

- Windows (PowerShell) is a full port. Same features, different idioms. Expected differences
  are language-level (ConvertFrom-Json vs jq, Write-Host vs printf, etc.). But the FEATURE
  SET and BEHAVIOR should match.

## What to check

### 1. Feature parity (HIGH PRIORITY)
- Every feature in statusline.sh (context bar, git status, cost, rate limits, subagent rows,
  idle detection, threshold notifications, burn-rate arrows, etc.) must exist on all 3 platforms.
- Every notification event (permission, stop, compaction_start, compaction_done, rate_limit,
  context_high) must be handled on all 3 platforms.
- Every installer capability (dependency check, settings merge, hook registration, notification
  config) must exist on all 3 platforms.

### 2. macOS/Linux drift (HIGHEST PRIORITY)
- These should be near-identical. Diff them carefully. Any behavioral difference beyond the
  known platform-specific items listed above is a bug.
- Check: same JSON fields extracted, same thresholds, same color codes, same formatting logic,
  same cache key computation, same git status parsing.

### 3. Behavioral equivalence with Windows
- Windows may use different syntax but must produce the same visual output and handle the same
  edge cases.
- Check: same threshold values, same color mappings, same row ordering, same cache TTLs,
  same notification events and messages.

### 4. Installer parity
- All three installers should register the same hooks, create the same config structure,
  and offer equivalent setup flows.

### 5. Uninstaller parity
- All three uninstallers should clean up equivalent artifacts.

## Output format

For each finding, cite specific file and line number (e.g., macos/statusline.sh:247, not
"lines 240-260").

Group findings by type:

**macOS/Linux drift** (these are likely bugs — should be near-identical):
- File pair, what differs, which side is correct (or if unclear, flag for review)

**Feature gaps** (present on some platforms, missing on others):
- Feature name, which platforms have it, which don't

**Behavioral divergence** (same feature, different behavior):
- What the difference is, which platform(s) diverge, suggested resolution

**Threshold/constant mismatches**:
- Variable name, values on each platform, which is correct

Only report real differences. Syntactic differences between Bash and PowerShell that produce
identical behavior are NOT findings. Focus on semantic and behavioral drift.
```

## Phase 1 — Write the master list to file

After all subagents return, aggregate their findings into a single markdown report and **write it to disk immediately** before doing anything else. This ensures the master list is preserved even if the session ends mid-verification.

### Output path

Write the file to `docs/code-review/`, creating the directory if needed. Use a scope-aware filename so different review modes don't overwrite each other:

| Mode | Filename |
|------|----------|
| Full | `YYYY-MM-DD-code-review.md` |
| Platform | `YYYY-MM-DD-code-review-{platform}.md` (e.g., `2026-05-20-code-review-macos.md`) |
| Script-type | `YYYY-MM-DD-code-review-{script-type}.md` (e.g., `2026-05-20-code-review-installer.md`) |

Use the first alias from the keyword mapping table as the slug (e.g., `installer`, not `install`). If a file with the same name already exists, overwrite it (a re-run supersedes the previous review).

### Report format

Use the template below verbatim as the skeleton. Fill in dynamic values where indicated.

````markdown
# Code Review — claude-status-line

> **Date:** YYYY-MM-DD
> **Reviewed by:** N parallel subagents (list agent roles based on dispatch mode)
> **Scope:** Describe the actual review scope (e.g., "All platform scripts", "macOS platform — 5 files", "Installer scripts across all platforms")

---

## Summary

| Severity | Count |
|----------|------:|
| Critical | N     |
| Warning  | N     |
| Parity   | N     |
| Nit      | N     |
| **Total**| **N** |

**Files reviewed:** N &nbsp;&nbsp;|&nbsp;&nbsp; **Clean files:** N &nbsp;&nbsp;|&nbsp;&nbsp; **Files with findings:** N

---

## Critical Issues

> Items that break functionality or violate the silent degradation contract. Must fix before shipping.

If none, write: *No critical issues found.*

Otherwise, for each finding use this block:

---

### C-N: `<short title>`

| | |
|---|---|
| **File** | `path/file.ext:LINE` |
| **Severity** | Critical |
| **Source** | macOS reviewer / Linux reviewer / Windows reviewer / Parity checker |

> In platform mode, append the file to disambiguate per-file agents (e.g., "macOS reviewer (notify.sh)").

**Description**

<1-3 sentences: what's wrong and why it matters>

**Suggested fix**

```diff
- <old code>
+ <new code>
```

---

## Warnings

> Incorrect behavior possible under certain conditions — edge cases, race conditions, missing guards.

If none, write: *No warnings found.*

Same finding block format as Critical, but numbered W-N.

---

## Cross-Platform Parity

> Drift, feature gaps, and behavioral divergence across macOS, Linux, and Windows.

If none, write: *All platforms are in sync.*

For parity findings, use a comparison table inside the finding block:

---

### P-N: `<short title>`

| | |
|---|---|
| **Files** | `macos/file.sh:LINE`, `linux/file.sh:LINE`, `windows/file.ps1:LINE` |
| **Severity** | Warning / Nit / Review |
| **Source** | Parity checker |

**Description**

<what differs and why it matters>

| Platform | Behavior |
|----------|----------|
| macOS    | <what macOS does> |
| Linux    | <what Linux does> |
| Windows  | <what Windows does> |

**Suggested resolution**

<which platform is correct, or flag for human review if unclear>

---

## Nits

> Style and convention issues that don't affect behavior.

If none, write: *No nits found.*

For nits, use a compact table — one row per finding, no expanded blocks:

| # | File | Description | Suggested fix |
|---|------|-------------|---------------|
| N-1 | `path:LINE` | ... | ... |
| N-2 | `path:LINE` | ... | ... |

---

## Clean Files

> These files were reviewed and had no issues.

| Platform | File | Status |
|----------|------|--------|
| macOS    | `statusline.sh` | Clean |
| macOS    | `install.sh` | Clean |
| ...      | ... | ... |

---

## Recommended Fix Order

> Prioritized action plan. Only includes CONFIRMED and PARTIAL findings from verification.

*Populated after Phase 2 verification.*

---

*Review generated by claude-status-line code-review skill.*
````

### Formatting rules

- **Finding IDs**: prefix with severity letter and sequential number — `C-1`, `C-2` for criticals, `W-1`, `W-2` for warnings, `P-1`, `P-2` for parity, `N-1`, `N-2` for nits. These make findings easy to reference in discussion.
- **Diff blocks**: use ` ```diff ` fenced blocks for suggested fixes so added/removed lines render in green/red.
- **Empty sections**: always include every section header even if empty — write the "none found" message. This confirms the category was checked, not skipped.
- **Horizontal rules** (`---`): place one between each expanded finding block to visually separate them.
- **Tables**: use right-aligned count column in the summary table (`------:|`).
- **Backtick paths**: always wrap file paths and line references in backticks.
- **No emojis.** Use text labels for severity, not icons.

### Deduplication and disagreement handling

- If the parity checker and an OS agent both flag the same issue, merge into one entry. Prefer the more specific description.
- **Platform agent vs. parity checker**: Prefer the platform-specific agent's judgment on whether behavior is correct for that platform. Prefer the parity checker's judgment on whether platforms should match.
- **Contradictory fixes**: If two agents suggest different fixes, include both and flag the disagreement for human review. Don't silently pick one.
- **Bug vs. intentional**: If one agent flags something as a bug and another implies it's intentional, use severity "review" with both perspectives.
- **Confidence mismatch**: If one agent is confident and another hedges, include the finding but note the split confidence.

---

## Phase 2 — Verify the master list

After writing the master list to disk, go through **every finding** and verify it against the actual code. This catches subagent hallucinations — wrong line numbers, misread logic, phantom bugs.

### Verification procedure

For each finding in the master list:

1. **Read the cited file and line** using the Read tool. Read enough context (the cited line +/- ~10 lines) to understand the surrounding logic.
2. **For parity findings**, read the corresponding code on all referenced platforms.
3. **Judge the finding**: Is it real? Is the line number correct? Is the description accurate?
4. **Assign a verdict**: one of three values:
   - `CONFIRMED` — the issue is real, line number is correct, description is accurate
   - `FALSE POSITIVE` — the issue does not exist, or the code is actually correct
   - `PARTIAL` — the issue is real but the description or line number is slightly off
5. **Write a 1-2 sentence reason** explaining the verdict.

### Updating the file

After verifying each finding, edit the master list file in place. Add the verification result inside the finding.

**For expanded finding blocks** (Critical, Warning, Parity): append a verification section at the bottom of the block, before the `---` separator:

```markdown
**Verification: CONFIRMED** — <1-2 sentence reason>
```
```markdown
**Verification: FALSE POSITIVE** — <1-2 sentence reason>
```
```markdown
**Verification: PARTIAL** — <1-2 sentence reason, including what's off>
```

**For compact nit rows**: add a `Verdict` column to the nits table:

```markdown
| # | File | Description | Suggested fix | Verdict |
|---|------|-------------|---------------|---------|
| N-1 | `path:LINE` | ... | ... | CONFIRMED — reason |
| N-2 | `path:LINE` | ... | ... | FALSE POSITIVE — reason |
```

**After verification is complete**, update the summary table to add a verification breakdown:

```markdown
| Severity | Count | Confirmed | False Positive | Partial |
|----------|------:|----------:|---------------:|--------:|
| Critical | N     | N         | N              | N       |
| Warning  | N     | N         | N              | N       |
| Parity   | N     | N         | N              | N       |
| Nit      | N     | N         | N              | N       |
| **Total**| **N** | **N**     | **N**           | **N**   |
```

Do NOT apply fixes or modify source code during verification. The verification phase produces annotations only — the user decides what to fix.

### Verification order

Process findings in severity order: critical first, then warnings, then parity, then nits. This ensures the most important items are verified even if the session runs long.

### Populate the recommended fix order

After all findings are verified, populate the "Recommended Fix Order" section in the report. Order fixes by:

1. **Critical issues** — fix first, in dependency order (if fix B depends on fix A, list A first)
2. **Cross-platform parity issues** — fix next, grouped by script type so all platforms get the same change atomically
3. **Warnings with multi-platform impact** — a warning affecting all 3 platforms ranks higher than a single-platform warning
4. **Single-platform warnings** — isolated issues
5. **Nits** — lowest priority, batch together

Only include CONFIRMED and PARTIAL findings. Omit FALSE POSITIVEs.

Use this table format:

```markdown
| Priority | Finding(s) | Files | Notes |
|----------|-----------|-------|-------|
| 1 | C-1 | `macos/statusline.sh`, `linux/statusline.sh`, `windows/statusline.ps1` | Fix across all platforms atomically |
| 2 | P-2, W-3 | `linux/notify.sh` | Linux-only, ports macOS behavior |
| ... | ... | ... | ... |
```

For each row, note whether the fix should be applied atomically across platforms (to maintain parity) or can be done independently.

---

## Tips

- The parity checker often surfaces the highest-value findings. Pay special attention to macOS/Linux drift since those scripts should be nearly identical.
- If a finding is ambiguous (could be intentional), flag it as "review" rather than "bug".
- The statusline scripts are the largest and most complex files in each platform folder. Most bugs hide there.
- Threshold values and color codes are common drift points — they get updated on one platform and forgotten on others.
- The reviewing subagents have runtime verification instructions. Findings they verified by actually running the scripts are higher confidence — weight them accordingly in the synthesis.
- The verification pass is sequential (one Read per finding). On a large finding list this may take many tool calls — that's expected and correct.
- **Choosing a scope**: Use platform mode for single-OS deep dives (e.g., debugging a macOS-only issue). Use script-type mode when porting a feature or fix across platforms — it reviews the same script on all three OSes plus parity in one pass.
