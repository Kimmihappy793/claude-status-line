---
name: code-review
description: >
  Multi-platform code review for claude-status-line with four scope modes: full project
  (3 OS agents + 3 logic auditors + parity checker), single-platform deep dive (one agent per file),
  script-type review across platforms, or diff-only review of uncommitted changes.
  Discovers files dynamically via Glob — never goes stale.
  Trigger on: "review", "code review", "audit", "check parity", "check all platforms",
  "diff", "quick", or any request to find bugs across the repo. Also triggers Phase 3
  (post-fix registry update) after fixing findings via /writing-plans, or when asked to
  "update the registry" or "mark findings as fixed".
---

# Code Review — claude-status-line

This skill runs a structured, parallel code review with dynamic file discovery and four scope modes.

## Phase 0 — Scope detection and file discovery

### Step 1: Detect scope

Parse the user's request to determine the review mode:

| Mode | Trigger | Dispatch |
|------|---------|----------|
| **Full** (default) | No qualifier, or "review everything" | 3 OS agents + 1 parity checker |
| **Platform** | Names a specific OS — "review macos/", "check windows scripts" | 1 agent per file in that folder |
| **Script-type** | Names a script type — "review installers", "check notify handlers" | 3 OS agents (scoped) + 1 parity checker |
| **Diff** | "diff", "quick", or auto-detect | Per-changed-platform agents + 1 parity checker |

**Diff mode trigger rules:**

- **Explicit:** User says "diff" or "quick" — enter diff mode immediately.
- **Auto-detect:** If no scope qualifier is given, run changed-file discovery (see Step 2a below). If platform script files are dirty, prompt:

  > "You have uncommitted changes in N script files. Review just the changes, or run a full review?"

  Use `AskUserQuestion` with options `[Diff only]` and `[Full review]`. If the user picks "Full review", proceed with full mode. If no platform script files are dirty, skip the prompt and default to full mode.

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

### Step 2a: Changed-file discovery (diff mode only)

Run two git commands via Bash and take their union:

```bash
git diff HEAD --name-only --diff-filter=ACMR
git ls-files --others --exclude-standard
```

Filter the union to paths matching `macos/*.sh`, `linux/*.sh`, `windows/*.ps1`. Drop all other paths.

**Empty result:** If no platform script files changed after filtering, print `"No script files changed — nothing to review."` and stop. Do not dispatch any agents.

### Step 3: Dispatch

Launch all subagents in a **single message** for concurrency. Use `subagent_type: "feature-dev:code-reviewer"` for all agents.

**Full mode** — 7 agents:

| Agent | Prompt | `{FILES}` value |
|-------|--------|-----------------|
| macOS reviewer | `references/prompt-macos.md` | All discovered `macos/` files |
| Linux reviewer | `references/prompt-linux.md` | All discovered `linux/` files |
| Windows reviewer | `references/prompt-windows.md` | All discovered `windows/` files |
| Parity checker | `references/prompt-parity.md` | All files, grouped by script type |
| macOS logic auditor | `references/prompt-logic.md` | All discovered `macos/` files |
| Linux logic auditor | `references/prompt-logic.md` | All discovered `linux/` files |
| Windows logic auditor | `references/prompt-logic.md` | All discovered `windows/` files |

**Platform mode** — one agent per file:

Dispatch one agent per discovered file in the target folder. Use the same OS prompt template as full mode, but set `{FILES}` to the single file name. The subagent will focus on the check categories relevant to that file type (each category heading indicates which file it applies to). No parity checker in platform mode.

**Script-type mode** — 4 agents (scoped):

Same dispatch as full mode, but `{FILES}` contains only the file(s) matching the script-type pattern per platform. The parity checker's `{ALL_FILES}` is similarly filtered.

**Diff mode** — per-changed-platform + parity:

Dispatch one agent per platform that has changed files, using the same OS prompt template as full mode. Set `{FILES}` to only the changed files for that platform.

**Always include the parity checker**, even if only one platform has changes. The most common parity bug is changing one platform without porting to the others — the parity checker catches this. Its `{ALL_FILES}` is the full file inventory (same as full mode).

| Changed files | Agents dispatched |
|---------------|-------------------|
| `windows/statusline.ps1` only | Windows reviewer + Parity checker (2) |
| `macos/notify.sh`, `linux/notify.sh` | macOS + Linux reviewers + Parity checker (3) |
| All three platforms | macOS + Linux + Windows + Parity (4, same as full) |

### Logic auditor dispatch

Logic auditors follow the same dispatch rules as OS reviewers across all modes:

| Mode | Logic auditors dispatched |
|------|--------------------------|
| Full | 3 (one per OS, all files) |
| Platform | 1 (same OS as the platform reviewers, same `{FILES}`) |
| Script-type | 3 (scoped to matching files per platform) |
| Diff | Per-changed-platform (same rule as OS reviewers) |

Logic auditors use `references/prompt-logic.md` with platform-specific placeholder substitution. They launch in the **same single message** as all other agents for concurrency.

### Reading prompt templates

Before dispatching, read the relevant prompt file(s) from the `references/` directory adjacent to this skill:

- `references/prompt-macos.md` — macOS reviewer prompt
- `references/prompt-linux.md` — Linux reviewer prompt
- `references/prompt-windows.md` — Windows reviewer prompt
- `references/prompt-parity.md` — Cross-platform parity checker prompt
- `references/prompt-logic.md` — Logic auditor prompt (used for all three platform logic auditors)

Each file contains a fenced code block with the full prompt template. Extract the content between the ``` fences — that is the prompt to send to the subagent.

### Placeholder substitution

Before sending each prompt, replace these placeholders with actual values:

- `{FILES}` — comma-separated file names from Glob (e.g., `statusline.sh, install.sh, notify.sh`)
- `{ALL_FILES}` — all files grouped by script type across platforms, one group per line. Match files across platforms by base name (e.g., `statusline`). Format:
  `macos/statusline.sh, linux/statusline.sh, windows/statusline.ps1`
  `macos/install.sh, linux/install.sh, windows/install.ps1`
  ...etc for each discovered script type.
- `{DIFF_CONTEXT}` — in **diff mode**: the unified diff output from `git diff HEAD -- <file>` for each file in the agent's scope. For the parity checker, diffs for all changed files grouped by platform. Preceded by this instruction block:

  ````
  ## Changed regions

  Focus your review on the changed regions shown in the diff below, but still apply all
  check categories. Flag anything in the changed code that introduces or exposes issues,
  even if the surrounding (unchanged) code is also involved.

  <diff output here>
  ````

  In **all other modes** (full, platform, script-type): empty string. The placeholder is invisible and agents behave identically to today.

- `{RUNTIME_VERIFICATION}` — host-OS-aware runtime verification instructions. Detect the host OS, then for each reviewer agent:
  - **Native platform** (e.g., macOS agent on macOS/Linux host, or Windows agent on Windows host): read the `## Runtime verification — full` section from the agent's prompt template file. Bash scripts are cross-compatible between macOS and Linux for basic testing.
  - **Non-native platform** (e.g., macOS agent on Windows host, or Windows agent on macOS host): read the `## Runtime verification — static` section from the agent's prompt template file.

  Host OS detection matrix:

  | Host OS | macOS agent | Linux agent | Windows agent |
  |---------|-------------|-------------|---------------|
  | Windows | static | static | full |
  | macOS   | full   | full   | static |
  | Linux   | full   | full   | static |

- `{PLATFORM}` — the platform folder name: `macos`, `linux`, or `windows`. Used only in logic auditor prompts.
- `{LANG}` — the scripting language: `Bash` for macOS/Linux, `PowerShell` for Windows. Used only in logic auditor prompts.
- `{LANG_NOTE}` — a one-sentence language context note. See the placeholder values table at the bottom of `references/prompt-logic.md` for the exact text per platform.
- `{FILE_EXT}` — the file extension: `sh` for macOS/Linux, `ps1` for Windows. Used only in logic auditor prompts.

Logic auditors also receive `{FILES}`, `{DIFF_CONTEXT}`, `{DETERMINISTIC_RESULTS}`, `{SUPPRESSED_SLUGS}`, and `{RUNTIME_VERIFICATION}` — identical values to the OS reviewer for the same platform. The `{RUNTIME_VERIFICATION}` host OS detection matrix applies the same way.

After all agents return, proceed to Phase 1 (synthesis).

## Phase 0.5 — Deterministic checks

Before dispatching LLM reviewers, run the deterministic check script to catch objective, repeatable issues. These results are consistent across runs — the same codebase always produces the same output.

### Running the script

**On macOS/Linux hosts**, run the Bash version:

```bash
bash <skill-dir>/scripts/check-parity.sh <project-root>
```

**On Windows hosts**, run the PowerShell equivalent:

```powershell
powershell -NoProfile -File <skill-dir>/scripts/check-parity.ps1 <project-root>
```

Both scripts output the same JSON format. Use the appropriate one for the current host OS.

Run with a 30-second timeout (`timeout: 30000` on the tool call). If the script times out, log a warning and proceed with `{DETERMINISTIC_RESULTS}` set to `"timed out — skipped"`. Reviewers will skip deterministic-result deduplication and rely on their own analysis.

The script outputs a JSON array of pass/fail assertions. Example:

```json
[
  {"check": "exit-0-termination", "passed": false, "file": "windows/git-refresh.ps1", "detail": "last non-blank line: Remove-Item ..."},
  {"check": "threshold-parity", "passed": true, "file": "statusline", "detail": "CONTEXT_WARN: macOS=60, Linux=60"}
]
```

### Reading the findings registry

Read `docs/code-review/findings-registry.json` if it exists. Extract the `suppressed_slugs` array — these are findings the user has already dismissed (`false_positive`, `wont_fix`).

### Injecting into prompts

Add two extra placeholders to each reviewer prompt before dispatching:

- `{DETERMINISTIC_RESULTS}` — the JSON output from the check script (or "skipped" on Windows)
- `{SUPPRESSED_SLUGS}` — comma-separated list of suppressed finding slugs from the registry (or "none")

### Invocation examples

```
# Full (default) — 3 OS agents + parity checker
/code-review

# Platform — one agent per file in the target folder
/code-review of macos scripts

# Script-type — 3 scoped OS agents + parity checker
/code-review of all installer scripts

# Diff — review only uncommitted changes
/code-review diff

# Quick (alias for diff)
/code-review quick

# Auto-detect — prompts if dirty tree, else runs full
/code-review
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
| Diff | `YYYY-MM-DD-code-review-diff.md` |

Use the first alias from the keyword mapping table as the slug (e.g., `installer`, not `install`). If a file with the same name already exists, overwrite it (a re-run supersedes the previous review).

### Report format

Read the report template, formatting rules, and deduplication/disagreement handling from `references/report-template.md` adjacent to this skill. That file contains the full markdown skeleton and all output conventions.

---

## Phase 1.5 — Update the findings registry

> **Diff mode:** Skip this phase entirely. Diff mode does not write to the findings registry. It still *reads* `suppressed_slugs` from the registry (in Phase 0.5) to filter known false positives.

After writing the master list, update the persistent findings registry at `docs/code-review/findings-registry.json`. This tracks findings across runs so you can see which bugs are consistently found (high confidence) vs. one-off noise.

### Registry schema

```json
{
  "last_updated": "YYYY-MM-DD",
  "findings": [
    {
      "id": "f-001",
      "fingerprint": "windows/statusline.ps1::start-process-nonewwindow-leak",
      "file": "windows/statusline.ps1",
      "slug": "start-process-nonewwindow-leak",
      "description": "Start-Process -NoNewWindow leaks child stdout into statusline stream",
      "severity": "critical",
      "first_seen": "2026-05-21",
      "last_seen": "2026-05-21",
      "hit_count": 1,
      "status": "new",
      "status_reason": ""
    }
  ],
  "suppressed_slugs": []
}
```

### Update procedure

For each finding in the master list:

1. **Compute the fingerprint**: `file_path::slug` (e.g., `windows/statusline.ps1::start-process-nonewwindow-leak`)
2. **Check the registry** for a matching fingerprint:
   - **Match found**: increment `hit_count`, update `last_seen` to today, keep existing `status`
   - **No match**: add a new entry with `hit_count: 1`, `status: "new"`, today's date for `first_seen` and `last_seen`
3. **Annotate the finding** in the master list report with registry info: "NEW" for first-time findings, "seen N times (status)" for recurring ones

### Stale entry detection

After processing all current findings, scan registry entries that were NOT seen in this run. If a finding's `file` path no longer exists or the code at the referenced location has changed substantially, mark it with `"status": "stale"` and add it to a "Stale Findings" note at the end of the report.

### If the registry doesn't exist

Create it with an empty `findings` array and empty `suppressed_slugs`. This is the first run.

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
6. **Triage the finding** via `AskUserQuestion`. The question depends on the verdict:

   **For CONFIRMED / PARTIAL findings:**

   > "<ID> confirmed: <short description>. What's your call?"

   | Option | Registry effect |
   |--------|-----------------|
   | Fix later (default) | Keeps `status: new` |
   | Won't fix | Sets `status: wont_fix`, adds slug to `suppressed_slugs` |
   | Actually false positive | Sets `status: false_positive`, adds slug to `suppressed_slugs` |

   **For FALSE POSITIVE findings:**

   > "<ID> appears to be a false positive: <reason>. Suppress in future reviews?"

   | Option | Registry effect |
   |--------|-----------------|
   | Yes, suppress (default) | Sets `status: false_positive`, adds slug to `suppressed_slugs` |
   | No, keep it | Keeps `status: new` |

7. **Update the registry immediately** after each triage decision. Edit `docs/code-review/findings-registry.json` in place — do not batch. This ensures the registry is consistent even if the session ends mid-verification.

8. **Annotate the report** with the triage decision after the verification line:

   ```markdown
   **Verification: CONFIRMED** — reason here
   **Triage: won't fix** — user dismissed: <reason from user or status_reason>
   ```

   For findings kept for fixing (the default), no triage annotation is needed.

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
| Severity | Count | Confirmed | False Positive | Partial | Dismissed |
|----------|------:|----------:|---------------:|--------:|----------:|
| Critical | N     | N         | N              | N       | N         |
| Warning  | N     | N         | N              | N       | N         |
| Parity   | N     | N         | N              | N       | N         |
| Nit      | N     | N         | N              | N       | N         |
| **Total**| **N** | **N**     | **N**          | **N**   | **N**     |
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

Only include CONFIRMED and PARTIAL findings that were NOT dismissed during triage (i.e., user chose "Fix later"). Omit FALSE POSITIVEs and user-dismissed findings.

Use this table format:

```markdown
| Priority | Finding(s) | Files | Notes |
|----------|-----------|-------|-------|
| 1 | C-1 | `macos/statusline.sh`, `linux/statusline.sh`, `windows/statusline.ps1` | Fix across all platforms atomically |
| 2 | P-2, W-3 | `linux/notify.sh` | Linux-only, ports macOS behavior |
| ... | ... | ... | ... |
```

For each row, note whether the fix should be applied atomically across platforms (to maintain parity) or can be done independently.

### Plan generation hook

When the user asks to fix findings (e.g., "fix these", "use /writing-plans to fix the findings"), and the fix plan is generated via `/writing-plans`, **you must append a final task** to the generated plan that invokes Phase 3. This is how Phase 3 gets triggered — it is a concrete task in the plan, not an implicit post-step.

The final task in the plan should read:

````markdown
### Task N: Update findings registry

**Files:**
- Modify: `docs/code-review/findings-registry.json`
- Modify: `docs/code-review/YYYY-MM-DD-code-review.md`

- [ ] **Step 1: Update the findings registry**

For each finding fixed by the preceding tasks, update its entry in `docs/code-review/findings-registry.json`:
- Set `"status"` to `"fixed"`
- Set `"status_reason"` to a summary of the fix including the actual code change

- [ ] **Step 2: Annotate the code review report**

For each fixed finding in the code review report, append after the verification line:

```markdown
**Fix applied** — <one-line summary of the change>
```

Update the summary table to add a "Fixed" column with counts.
````

This ensures the registry update is a tracked, executable step — not something the orchestrator has to remember.

---

## Phase 3 — Post-fix registry update

After findings are fixed (via `/writing-plans` → plan execution, or manual edits), update the findings registry and code review report to record what changed. This is the final step after fixes are applied.

### Trigger

Phase 3 is triggered by the final task in a code-review fix plan (see "Plan generation hook" above). It can also be invoked manually if the user says "update the registry" or "mark findings as fixed" after making changes themselves.

### Procedure

For each finding that was targeted by the fix plan:

1. **Read the modified file** at the location cited in the finding. Read enough context (~10 lines around the change) to capture the fix.

2. **Extract the fix code.** Compare the current code against the finding's "Suggested fix" to confirm the change was applied. The relevant code is what replaced the problematic pattern — not the entire function or block.

3. **Update the registry entry** in `docs/code-review/findings-registry.json`:
   - Set `"status": "fixed"`
   - Set `"status_reason"` to a concise description of the fix including the actual code. Format:

     ```
     <one-line summary of what changed>:\n<the key lines of the fix, as they appear in the file>
     ```

     Keep it short — just the lines that directly address the finding, not surrounding context. Use `\n` for line breaks within the JSON string.

4. **Leave non-fixed findings unchanged.** Only update entries for findings that were actually addressed. Findings the user dismissed (`false_positive`, `wont_fix`) or chose not to fix retain their existing status.

### Findings not targeted by the plan

If the user only fixed a subset of findings, the remaining `"new"` entries stay as-is. They will be re-evaluated on the next review run — if the code has changed enough that the finding no longer applies, stale-entry detection (Phase 1.5) will catch it.

### Status values reference

| Status | Meaning | Set by |
|--------|---------|--------|
| `new` | First-time finding, not yet acted on | Phase 1.5 (review run) |
| `fixed` | Code changed to resolve the finding | Phase 3 (post-fix) |
| `false_positive` | Finding is incorrect — the code is right | User triage |
| `wont_fix` | Finding is real but intentional | User triage |
| `stale` | Code changed substantially; finding may no longer apply | Phase 1.5 (stale detection) |

### Registry schema addition

The `"fixed"` status uses the same schema as other statuses. No new fields required — `status_reason` carries the fix details. Example:

```json
{
  "id": "f-002",
  "fingerprint": "windows/statusline.ps1::start-process-nonewwindow-leak",
  "file": "windows/statusline.ps1",
  "slug": "start-process-nonewwindow-leak",
  "description": "Start-Process -NoNewWindow may flash console window when parent has no visible console",
  "severity": "warning",
  "first_seen": "2026-05-21",
  "last_seen": "2026-05-21",
  "hit_count": 1,
  "status": "fixed",
  "status_reason": "Replaced -NoNewWindow with -WindowStyle Hidden at both notification dispatch sites:\nStart-Process -WindowStyle Hidden -FilePath 'powershell' -ArgumentList ..."
}
```

### Updating the code review report

After updating the registry, also update the code review report (`docs/code-review/YYYY-MM-DD-code-review.md`):

1. Add a `**Fix applied**` annotation to each fixed finding block, after the verification line:

   ```markdown
   **Verification: CONFIRMED** — <reason>

   **Fix applied** — <one-line summary of the change>
   ```

2. Update the summary table to add a "Fixed" column:

   ```markdown
   | Severity | Count | Confirmed | False Positive | Partial | Fixed |
   |----------|------:|----------:|---------------:|--------:|------:|
   | Critical | N     | N         | N              | N       | N     |
   | Warning  | N     | N         | N              | N       | N     |
   | Parity   | N     | N         | N              | N       | N     |
   | Nit      | N     | N         | N              | N       | N     |
   | **Total**| **N** | **N**     | **N**          | **N**   | **N** |
   ```

---

## Tips

- The parity checker often surfaces the highest-value findings. Pay special attention to macOS/Linux drift since those scripts should be nearly identical.
- If a finding is ambiguous (could be intentional), flag it as "review" rather than "bug".
- The statusline scripts are the largest and most complex files in each platform folder. Most bugs hide there.
- Threshold values and color codes are common drift points — they get updated on one platform and forgotten on others.
- The reviewing subagents have runtime verification instructions. Findings they verified by actually running the scripts are higher confidence — weight them accordingly in the synthesis.
- The verification pass is sequential (one Read per finding). On a large finding list this may take many tool calls — that's expected and correct.
- **Choosing a scope**: Use platform mode for single-OS deep dives (e.g., debugging a macOS-only issue). Use script-type mode when porting a feature or fix across platforms — it reviews the same script on all three OSes plus parity in one pass.
- **Diff mode** is designed for pre-commit quick checks. It dispatches fewer agents (only platforms with changes + parity) and skips registry writes. Use it to catch issues in uncommitted work before running a full review.
