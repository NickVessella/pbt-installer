#!/bin/bash
#
# Plan-Build-Test (PBT) Installer for Cursor
#
# Sets up the PBT workflow in ~/.cursor/ so every Agent mode prompt
# triggers structured plan-build-test and POSTs metrics to the team dashboard.
#
# Usage:
#   bash install.sh
#   # or
#   curl -fsSL <raw-github-url>/install.sh | bash

set -euo pipefail

CURSOR_DIR="$HOME/.cursor"
BACKUP_TS=$(date +%Y%m%d%H%M%S)

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }
dim()    { printf '\033[2m%s\033[0m\n' "$1"; }

backup_if_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    local bak="${path}.bak.${BACKUP_TS}"
    cp "$path" "$bak"
    dim "  backed up → $(basename "$bak")"
  fi
}

installed=()
skipped=()
backed_up=()

# ─────────────────────────────────────────────
# 1. Rule: ~/.cursor/rules/plan-build-test.mdc
# ─────────────────────────────────────────────
install_rule() {
  local dir="${CURSOR_DIR}/rules"
  local file="${dir}/plan-build-test.mdc"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'RULE_EOF'
---
description: Enforce Plan-Build-Test workflow on all coding tasks across every project
alwaysApply: true
---

# Plan-Build-Test Workflow

## Mode gate — skip in read-only modes

If the current interaction mode is **Plan**, **Debug**, or **Ask**, the PBT workflow does NOT apply. Do NOT read the SKILL.md file, do NOT output a triage label, do NOT log. Answer the user's question or complete the planning/debugging task normally. Stop reading this rule here.

---

For **every coding task** in **Agent mode** — new features, bug fixes, refactoring, edits, style changes, implementation — follow the full workflow defined in:

`~/.cursor/skills/plan-build-test/SKILL.md`

Read that file at the start of any coding task in this session if you haven't already. It is not optional and applies across all projects.

## Non-negotiables (minimum enforcement without reading the file)

1. **First output line** of every coding response MUST be the triage label — before any tool call, before reading any file:
   - `P.B.T. Trivial: make the change, no plan needed`
   - `P.B.T. Small Scope: abbreviated plan, then build and test`
   - `P.B.T. Complex: full plan-build-test workflow`
   - `P.B.T. Investigative: spike first, then plan-build-test`

2. **Last action** of every task is logging. Append a single-line JSON entry to `~/.pbt-log.jsonl`. The task is NOT complete until this is written.

3. **Log schema** lives at `~/.cursor/skills/plan-build-test/scripts/log-schema.md` — use the exact field names defined there.
RULE_EOF

  green "✓ Rule installed → ${file}"
  installed+=("rules/plan-build-test.mdc")
}

# ─────────────────────────────────────────────────────────
# 2. Skill: ~/.cursor/skills/plan-build-test/SKILL.md
# ─────────────────────────────────────────────────────────
install_skill() {
  local dir="${CURSOR_DIR}/skills/plan-build-test"
  local file="${dir}/SKILL.md"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'SKILL_EOF'
---
name: plan-build-test
description: Structured coding workflow that triages requests by complexity. Automatically applies when the user asks for code changes, new features, refactoring, bug fixes, or implementation work. Enforces plan-then-build-then-test phases for complex changes while fast-tracking simple ones.
---

# Plan-Build-Test Workflow

**This workflow only applies in Agent mode.** The `plan-build-test.mdc` rule gates on mode — if the user is in Plan, Debug, or Ask mode, the rule short-circuits before reading this file, saving tokens. If you are reading this file, you are in Agent mode and must follow the full workflow.

---

> **⛔ MANDATORY FIRST ACTION — READ THIS EVERY TIME**
>
> Your very first output line for any coding task MUST be your triage label:
>
> `P.B.T. Trivial: make the change, no plan needed`
> `P.B.T. Small Scope: abbreviated plan, then build and test`
> `P.B.T. Complex: full plan-build-test workflow`
> `P.B.T. Investigative: spike first, then plan-build-test`
>
> This line must appear **before any tool call** — before reading files, before searching code, before anything. If you called a tool before outputting this line, you have already violated the workflow. Reading files to "understand the problem" is not pre-work — it is part of the build phase. Triage is based on the user's request, not on inspecting the code.
>
> **⛔ Anti-pattern: reading code to reduce triage uncertainty.** You will feel the urge to grep or read files before committing to a tier — "what if I call it Small Scope but it's actually Complex?" This is procrastination dressed as diligence. A wrong tier is cheap: you can escalate mid-task (Small Scope → Complex) with a one-line note. A pre-triage tool call is an unrecoverable violation — you cannot un-read the code.
>
> **Classify from the request, not the implementation.** These signals are visible in the user's description alone:
> - New component/module/service needed → at least Complex
> - Wired into 3+ locations → at least Complex
> - New dependency → at least Complex
> - Single file, no decisions → Trivial
> - Existing pattern, 1-3 files, obvious approach → Small Scope
> - Prior attempts failed or root cause unclear → Investigative
>
> When a non-coding preamble (reading a ticket, fetching context) transitions to the coding task, that transition is where the label must appear. The preamble does not count as "starting the task" — the first code-related tool call does.
>
> **The task is NOT complete until Step 5 (Log) is finished.** Do not tell the user you are done until the log entry is written.

---

## Step 1: Triage

Before classifying, handle these special cases in order:

- **Vague request** (e.g., "make the app better", "improve performance"): Ask the user to specify what to change before proceeding. You cannot triage without a concrete scope.
- **Multi-task request** (e.g., "fix the typo and also add auth"): Split into sub-tasks. Handle Trivial parts immediately, then apply the appropriate workflow to the rest.
- **Visual layout task detection**: If the request describes positioning, alignment, layout, animation, CSS/styles, SVG placement, or visual appearance — set `VISUAL_TASK=true`. This flag forces visual verification regardless of tier (including Trivial). State `[visual task]` inline after your triage label when this applies.
- **Retry detection**: Before classifying, run this command — replacing `HINT` with a keyword from the filename or task description — to count how many recent entries involve the same work:
  ```bash
  tail -3 ~/.pbt-log.jsonl 2>/dev/null | python3 -c "
  import sys, json
  count = 0
  for line in sys.stdin:
      line = line.strip()
      if not line: continue
      try:
          e = json.loads(line)
          haystack = str(e.get('files_changed','')) + str(e.get('task','')) + str(e.get('notes',''))
          if 'HINT' in haystack:
              count += 1
      except: pass
  print(count)
  "
  ```
  Apply graduated escalation based on the count:
  - **1 prior attempt** → bump tier one level (Trivial → Small Scope, Small Scope → Complex). Note `[retry escalation]` after triage label.
  - **2+ prior attempts** → if `VISUAL_TASK=true`, classify as **Investigative** regardless of original tier. Otherwise bump to Complex. Note `[retry ×N escalation]` after triage label.

Classify the request into one of three categories. Output the full `P.B.T.` label (including the description) as the first line of your response, then proceed.

### TRIVIAL — Make the change, no plan needed

All of these must be true:
- Touches 1-2 files max
- No design decisions or trade-offs
- Obvious single correct implementation
- No new logic that changes program behavior

**If Trivial:** Make the change directly. Briefly state what you did. If `VISUAL_TASK=true`, perform the visual check from Step 4 before stopping. Then log (Step 5). Stop after logging.

### SMALL SCOPE — Abbreviated plan, then build and test

Use Small Scope when the change has some complexity but is still contained:
- Touches 1-3 files
- Adds straightforward logic to an existing pattern (e.g., a new state variable, a try/catch, moving code between files)
- Low risk of breaking other code
- The approach is obvious even without detailed planning

**If Small Scope:** Output a plan using this exact format before writing any code, then implement, run existing tests, and write tests for any new logic. No formal risk analysis needed.

> **Goal:** _one sentence_
> **Files:** _list each file and what changes_
> **Approach:** _1-3 sentences on how_
> **Visual:** _UI change? State which route to check. Modifying existing UI? Capture a browser snapshot now before building._

> **⛔ If your Approach sentence uses hedging language about whether something will work, STOP.** Use `AskQuestion` to present the options to the user, or escalate to Investigative. A Small Scope plan must not contain speculation.

### COMPLEX — Full plan-build-test workflow

A request is Complex when it has real scope AND real risk. Look for a combination of these signals -- a single signal alone is not enough unless it's clearly high-impact:
- Touches 3+ files with logic changes (not just import updates)
- Introduces new modules, services, or architectural patterns
- Changes interfaces or contracts that other code depends on
- Multiple valid approaches with meaningful trade-offs
- Changes data models in ways that cascade (API, validation, frontend, DB)
- Could introduce subtle bugs or break existing behavior across boundaries

**If Complex:** Continue to Step 2.

### INVESTIGATIVE — Spike first, then plan-build-test

Use Investigative when the correct fix cannot be determined by reading code alone:
- Visual or layout bug where rendering behavior is the unknown (not the logic)
- The same file/feature has 2+ prior failed attempts (`VISUAL_TASK=true`)
- Race condition, environment-specific failure, or emergent behavior
- You would need to speculate in the plan because the root cause is genuinely unclear
- Unfamiliar platform API or runtime (Tauri, WKWebView, CoreAudio, native bridges, SVG filters)
- Visual effect where the rendered output cannot be predicted from reading code alone
- The approach would rely on assumptions about runtime behavior ("should work", "might need")

**If Investigative:** Proceed to Step 1.5 (Spike) before writing a plan.

---

## Step 1.5: Spike

> **Investigative tasks only.** The goal of a spike is to generate knowledge, not ship code. Output is a confirmed root cause and fix approach — not committed changes (unless the exception below applies).

> **⛔ DO NOT THEORIZE.** Reasoning about root causes without making a change is not a spike — it is just planning, and it is what failed before. Make a change. Observe the result. That is the only output that counts. If you find yourself writing more than 2 sentences of reasoning without having made a code change, stop and make the change instead.

> **⛔ DO NOT WRITE DIAGNOSTIC SCRIPTS WHEN READING THE FILE WOULD WORK.** If the problem is a structural/syntax issue (mismatched tags, missing brackets, wrong indentation), read the relevant section of the file directly and count visually. Writing Python/shell scripts to parse JSX or count divs is slower and less reliable than `Read` at the right line offset. Scripts are appropriate only when the file is too large to read in context or the pattern spans hundreds of lines.

**How to spike:**
1. State your hypothesis in one sentence
2. Make the candidate change
3. Verify visually (see visual verification rules below)
4. Note what you observed — did it move the problem, fix it, or reveal something new?
5. Repeat with a revised hypothesis if needed — **3 attempts max**

**Visual verification during a spike:**

First, try to take a browser snapshot (browser-use tool or Playwright). If that works, use it.

**If the app is not snapshottable** (embedded in an iframe, auth-gated, requires a native device, or otherwise inaccessible to automated browser tools) — do NOT discuss the situation, do NOT ask about verification setup, do NOT theorize. **Make the candidate change first.** Then use the user-as-eyes protocol:
> Tell the user exactly what you changed and exactly what to look for:
> *"I've changed X. Please [specific action — reload, navigate to Y, trigger Z]. Does [specific thing] look correct now?"*
> Then **stop and wait** for their response before iterating or proceeding to Step 2.

> **⛔ The question about HOW to verify comes after the change, never before.** If you find yourself explaining browser access, tunnel URLs, or authentication before making a code change, you have violated this step.

**When done, output:**
> **Root cause:** _one sentence — what was actually causing the problem_
> **Confirmed fix:** _one sentence — what to change and why it works_
> **Verified by:** _snapshot / user confirmed / user reported still broken_
> **Reverted:** yes / no (see exception below)

**Revert rule:** Revert ALL spike changes before proceeding to Step 2. The spike output is knowledge. You will re-implement the fix cleanly in Step 3.

**Exception:** If the confirmed fix is 1-2 lines, clearly correct, and already in place — keep it, skip Step 3, and proceed directly to Step 4 → Step 5. Note `spike_resolved: true` in the log.

---

## Step 2: Plan

Output the plan under a `## Plan` heading before writing any code.

**Required sections:**

1. **Goal** — One sentence: what does this change accomplish?

2. **Files** — Every file to create or change, with a one-liner on what changes and why. This is a checklist for the Build phase -- nothing should be a surprise later.

3. **Approach** — 3-8 bullets covering:
   - Pattern or architecture to follow
   - Key decisions (if alternatives exist, briefly note why this one)
   - Order of operations and dependencies

> **⛔ Speculation circuit breaker.** While writing Approach bullets, if you catch yourself using hedging language ("should", "might", "probably", "I believe", "hopefully", "in theory") about runtime/platform/rendering behavior — STOP writing the plan. You have two options:
>
> 1. **Ask the user.** Use the `AskQuestion` tool to present the competing hypotheses as choices. State what you know, what you don't, and let the user pick which to try. Then spike that one.
> 2. **Escalate to Investigative.** Drop the plan, note `[mid-plan spike]`, and proceed to Step 1.5 (Spike).
>
> **Hard cap:** If your Approach section would contain more than 2 bullets that reference unknowns, escalation to Investigative is mandatory — you cannot plan around 3+ unknowns.

4. **Risks and resolutions** — Every risk must have a resolution. For each risk, state one of:
   - **Mitigate**: describe how the implementation will handle it
   - **Out of scope**: explicitly note it won't be addressed and why
   - **Ask user**: flag it as a question that needs answering before proceeding

   If any risk is marked "Ask user", STOP and ask before continuing to Step 3.

5. **Test strategy** — What to verify in Step 4:
   - Existing test suites to run
   - New test cases needed (describe the cases, not the code)
   - At minimum: one success path, one error/edge case per new behavior

6. **Visual check** (only if the change modifies UI — components, styles, templates, layouts, animations):
   - Which page(s)/route(s) to verify after building
   - If the change modifies *existing* UI (not purely additive), capture a browser snapshot of the current state now as a before-baseline for comparison in Step 4

**Rules:**
- Keep it concise. Every line should be specific to this task. No generic advice.
- Total plan should be under 25 lines.
- Do NOT write any code during this step.
- **Mid-plan escalation.** If the speculation circuit breaker fires, you may escalate directly from Complex to Investigative (or Small Scope to Investigative). Note `[mid-plan spike]` after the triage label. The existing `escalated` / `escalated_from` log fields track this, plus `mid_plan_spike: true`.

---

## Step 3: Build

Implement under a `## Build` heading.

**Rules:**
- Follow the plan's file list and approach. Use the file list as a checklist.
- If you need to deviate from the plan, note what changed and why in a single line.
- Write production code first; tests come in Step 4.
- Don't skip planned files. If a planned change turns out unnecessary, note why.

> **⛔ BUILD DONE ≠ TASK DONE.** After the code compiles cleanly, output `## Test` and proceed to Step 4. If your plan included a visual check, that check is mandatory. Do not summarize, do not tell the user "done" — you are halfway through.

---

## Step 4: Test

**Checklist (complete all that apply):**
1. **Build gate (mandatory).** Run the project's compile/build command (`tsc --noEmit`, `npm run build`, or equivalent) on every edit — including Trivial fixes. If it fails, fix before continuing. This is not optional. A lint-only check does not replace a build pass; linters do not catch TDZ errors, unclosed JSX, or missing imports that a full compile does.
2. **Runtime gate (mandatory for web projects).** After the build passes, confirm the app actually serves a page. Skip only for libraries, CLI tools, or projects with no running server.
   - If a dev server is running (check terminal output or `lsof -i :3000` / equivalent port), hit the main route with `curl -s -o /dev/null -w '%{http_code}' http://localhost:<port>` and confirm a 2xx response.
   - If the response is not 2xx, or the body contains error signatures (`Server Error`, `Cannot find module`, `Internal Server Error`, `502`, `503`, Cloudflare error tokens), the gate fails.
   - **Stale cache recovery:** If the error matches a module-not-found pattern (e.g., `Cannot find module './XXX.js'`), delete the build cache directory (`.next`, `dist`, `.cache`, or equivalent), restart the dev server, and re-check. This catches `.next` desync from running `npm run build` while the dev server is active.
   - If no dev server is running and the project is a web app, start it, wait for the ready signal, run the check, then stop it (or leave it running if the user's workflow expects it).
   - **Stylesheet sanity check:** After confirming a 2xx response, fetch the page HTML and verify that stylesheet links actually resolve. Run:
     ```bash
     curl -s http://localhost:<port> \
       | grep -oP '(?<=href=")[^"]*\.css[^"]*' \
       | while read href; do
           url=$(echo "$href" | grep -q '^http' && echo "$href" || echo "http://localhost:<port>$href")
           status=$(curl -s -o /dev/null -w '%{http_code}' "$url")
           [ "$status" != "200" ] && echo "FAIL: $href returned $status" && exit 1
         done
     ```
     If any stylesheet returns non-200, the runtime gate fails. A page can return 200 OK with completely broken styles — this check catches the "CSS file 404" class of bugs that a status-code-only check misses.
   - **User load confirmation (dev server already running only).** If a dev server was already running when the runtime gate started (i.e., you did not start it), use `AskQuestion` to prompt the user:
     > *"The app is serving on localhost:\<port\>. Did it load correctly in your browser?"* — options: **Yes** / **No**
     - **Yes**: runtime gate passes, continue to item 3.
     - **No**: escalate the current task to **Investigative** tier. Note `[load-check escalation]` after the triage label. Set `escalated: true` and `escalated_from` to the current tier in the log. Proceed to Step 1.5 (Spike) to diagnose the loading issue before continuing.
   - **Failure = blocker.** Do not proceed to tests or visual verification until the runtime gate passes (including the stylesheet check and user confirmation above). A build that compiles but crashes at runtime is not a passing build.
3. **Run existing tests** that cover modified code. If any fail, fix them before continuing.
4. **Write new tests** for every new behavior introduced:
   - Primary success path
   - At least one error or edge case
   - Any boundary conditions identified in the plan's risks
5. **Run all tests** (existing + new) and confirm they pass.
6. **Run linters** on all modified and new files. Fix any issues.
7. **Visual verification** — mandatory when `VISUAL_TASK=true` (set in Step 1), OR when the change touches UI-rendering files (components, styles, templates, layouts, animations). Skip only for backend-only, config, or pure logic changes where `VISUAL_TASK` was not set.
   - First, try to take a browser snapshot (browser-use tool or Playwright). If that works, use it.
   - Verify: correct layout, styles applied, no clipping/overflow, z-index correct, animation plays
   - If a before-state snapshot was captured in Step 2, compare against it — flag anything that changed outside the intended scope
   - If the project has visual regression tooling (Playwright screenshots, Chromatic, Percy), run it
   - **Token budget:** one snapshot per affected route, max three total. Do not loop or re-snapshot unless something is visibly broken.
   - **If the app is not snapshottable** (embedded iframe, auth-gated, native device required): use the user-as-eyes protocol — tell the user exactly what changed and exactly what to check, then stop and wait for confirmation before logging done. Do NOT silently skip the visual check and log `visual_check: false`. That is a workflow violation.
   - **⛔ If your plan listed a visual check, you MUST complete it — either by snapshot or by user confirmation.** Fixing a build error does not replace visual verification. If you declare done without one of these, you have violated the workflow.
   - **⛔ Do NOT write the log entry until the visual check is confirmed.** The log is the last step. Asking the user to check, then immediately logging `visual_check: true`, then saying "done" is a violation — the user's confirmation must arrive before the log is written.

**Rules:**
- Match the testing patterns already in the project (framework, file location, naming). Look at existing tests before writing new ones.
- If the project has no tests, create a reasonable test file following standard conventions for the language.
- If the test runner command isn't obvious, check for config files (package.json for npm test/jest, pyproject.toml/pytest.ini/setup.cfg for pytest, Makefile, go.mod for go test) before asking the user.

> **⛔ Bugfix cascade rule.** When the user reports an error after your edit (syntax error, runtime crash, broken UI), you are still inside the P.B.T. workflow — not in a free-form debug loop. Every fix, no matter how small, requires the build gate (item 1) and runtime gate (item 2) to pass before you report back. Do not tell the user "try again" until you have confirmed a clean build that actually serves. Two consecutive user-reported errors on the same edit means you missed a gate — escalate to Small Scope or Complex and write a plan before your next attempt.

> **⛔ TESTS DONE ≠ TASK DONE.** Output `## Log` and proceed to Step 5. You are one step away from done — do not skip it.

---

## Step 5: Log

> **⛔ Final gate.** Write the log entry before declaring done. Do NOT write the log until the visual check (if required) is confirmed by the user or a snapshot.

After every completed task (including Trivial), log metrics.

**⛔ MANDATORY: Re-read the schema file before writing the log.** Do not write the log from memory. Field names have exact spellings — aliases (`timestamp`, `tier`, `goal`, `files_touched`) will corrupt the log.

```bash
cat ~/.cursor/skills/plan-build-test/scripts/log-schema.md
```

Then:

1. Build the JSON payload using ONLY the field names in the schema
2. Pipe the JSON line to the log helper script:
   ```bash
   echo '{"ts":"...","user":"..."}' | ~/.cursor/hooks/pbt-log.sh
   ```
   **⛔ Do NOT use `printf` or `echo` with `>>` to write directly to `~/.pbt-log.jsonl`.** Direct writes trigger an approval prompt in Cursor IDE on every task because the payload is unique each time. The helper script has a fixed name that can be allowlisted once.
3. If `$PBT_SLACK_WEBHOOK` is set, send to Slack per the reference file

If the pipe or curl command fails, note the failure to the user and move on — a logging failure should not block the user. But you must *attempt* it before declaring done.

**Field reference** (how to populate non-obvious fields):
- `tests_written`: count of new test cases (not files), 0 for Trivial tasks
- `tests_fixed`: pre-existing broken tests you repaired
- `risks_*`: only populated for Complex tasks (0 for Trivial/Small Scope)
- `visual_check`: true if visual verification was performed (Step 4, or Trivial with `VISUAL_TASK=true`)
- `visual_issues_found`: count of visual issues caught and fixed during verification
- `escalated`: true if tier was bumped during triage (retry escalation), mid-task, or via load-check escalation (user answered "No" to the runtime gate load confirmation)
- `escalated_from`: the original tier before escalation (e.g. `"Trivial"`, `"Small Scope"`), null if not escalated. Applies to retry escalation, mid-plan escalation, and `[load-check escalation]` alike
- `pre_existing_issues`: array of short strings, e.g. `["broken test", "circular dep"]`
- `spiked`: true if Step 1.5 (Spike) was performed (Investigative tasks only)
- `spike_resolved`: true if the spike fix was kept in place and Step 3 was skipped (1-2 line exception)
- `mid_plan_spike`: true if the speculation circuit breaker fired during Step 2 and the agent escalated to Investigative mid-plan
- `duration_min`: optional — elapsed minutes if known, null otherwise
- `notes`: optional — one-sentence context for unusual situations, null otherwise

---

## Keywords

Keywords are commands the user can type at any point during a session. They interrupt the current workflow, execute, and return control. Keywords are prefixed with `--`.

### `--startbackup`

Create a git backup and log the session. Follow the project's `startbackup-command` rule (typically `.cursor/rules/startbackup-command.mdc`) for project-specific paths and rotation logic.

**Default behavior if no project rule exists:**
1. Check the retry count for the current task: read the last 3 log entries and count how many match the current task keyword (same logic as Step 1 retry detection).
2. Stage all changes and commit: `backup: <date> - <1-line summary>` — if retry count > 0, append `[attempt <N+1>]` to the summary (e.g. `backup: 2026-03-30 - fix gooey neck z-index [attempt 2]`).
3. Do NOT push unless explicitly asked

### `--ticket`

Find or create a Linear ticket for the current work.

**Step 1 — Infer the task.** From the conversation context (what the user asked for, what files were edited, what the P.B.T. plan says), compose a 3-5 word summary of the work being done. This becomes the search query.

**Step 2 — Search for existing tickets.** Use the Linear MCP `search_issues` tool with the inferred summary as the `search` filter. Scope to the project's team using the `teamId` from the project's `linear-ticket-workflow` rule. Request the top 5 results.

**Step 3 — Present results.**
- If matches are found, list them with identifier, title, and current state. Ask: *"Any of these match what you're working on? Or should I create a new ticket?"*
- If no matches (or user says create new), proceed to Step 4.

**Step 4 — Create a ticket.** Use the Linear MCP `create_issue` tool:
- `title`: concise summary of the work
- `teamId`: from the project's `linear-ticket-workflow` rule
- `description`: 2-3 sentence description of what's being done, derived from conversation context
- `priority`: infer from context (default `medium`)

**Step 5 — Ask the user.** After finding or creating the ticket:
> *"Do you want to work on this ticket now, or save it for later?"*

- **Work now** (user says yes, start, pick it up, work on it, etc.): Set state to In Progress and assign to user using IDs from the project's `linear-ticket-workflow` rule. Confirm.
- **Save for later** (user says later, save, backlog, etc.): Leave the ticket in its current state. Confirm it's saved.
SKILL_EOF

  green "✓ Skill installed → ${file}"
  installed+=("skills/plan-build-test/SKILL.md")
}

# ───────────────────────────────────────────────────────────────────
# 3. Log schema: ~/.cursor/skills/plan-build-test/scripts/log-schema.md
# ───────────────────────────────────────────────────────────────────
install_log_schema() {
  local dir="${CURSOR_DIR}/skills/plan-build-test/scripts"
  local file="${dir}/log-schema.md"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'SCHEMA_EOF'
> **⛔ STRICT SCHEMA** — Use ONLY the field names listed below. Do not use aliases (`timestamp` instead of `ts`, `tier` instead of `triage`, `files_touched` instead of `files_changed`, `goal` instead of `task`, etc.). Any field not in this list must not appear in the log entry, with the exception of the two optional fields at the bottom.

```json
{
  "ts": "ISO 8601 timestamp",
  "user": "$(whoami)",
  "project": "basename of the git repo root, or current directory name if not a repo",
  "triage": "Trivial | Small Scope | Complex | Investigative",
  "task": "one-sentence summary of what was done",
  "files_changed": 0,
  "files_created": 0,
  "tests_written": 0,
  "tests_fixed": 0,
  "all_tests_passed": true,
  "risks_identified": 0,
  "risks_mitigated": 0,
  "risks_out_of_scope": 0,
  "risks_ask_user": 0,
  "stopped_to_ask_user": false,
  "plan_deviations": 0,
  "pre_existing_issues": [],
  "language": "primary language of the change (js, ts, py, go, etc.)",
  "visual_check": false,
  "visual_issues_found": 0,
  "escalated": false,
  "escalated_from": null,
  "spiked": false,
  "spike_resolved": false,
  "mid_plan_spike": false,
  "duration_min": null,
  "notes": null
}
```
SCHEMA_EOF

  green "✓ Log schema installed → ${file}"
  installed+=("skills/plan-build-test/scripts/log-schema.md")
}

# ─────────────────────────────────────────────────────
# 4. Hooks JSON: ~/.cursor/hooks.json (MERGE, not overwrite)
# ─────────────────────────────────────────────────────
install_hooks_json() {
  local file="${CURSOR_DIR}/hooks.json"
  backup_if_exists "$file"

  local result
  result=$(python3 -c "
import json, os, sys

hooks_path = os.path.expanduser('~/.cursor/hooks.json')
pbt_entry = {'command': './hooks/pbt-stop.sh', 'timeout': 15}

if os.path.exists(hooks_path):
    try:
        with open(hooks_path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        data = {'version': 1, 'hooks': {}}
else:
    data = {'version': 1, 'hooks': {}}

if 'hooks' not in data:
    data['hooks'] = {}
if 'version' not in data:
    data['version'] = 1

if 'stop' not in data['hooks']:
    data['hooks']['stop'] = []

already = any(
    e.get('command') == './hooks/pbt-stop.sh'
    for e in data['hooks']['stop']
)

if already:
    print('SKIPPED')
else:
    data['hooks']['stop'].append(pbt_entry)
    with open(hooks_path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print('INSTALLED')
")

  if [ "$result" = "SKIPPED" ]; then
    green "✓ hooks.json — stop hook already present (no changes)"
    skipped+=("hooks.json (already had pbt-stop)")
  else
    green "✓ hooks.json — stop hook merged"
    installed+=("hooks.json")
  fi
}

# ──────────────────────────────────────────
# 5. Stop hook: ~/.cursor/hooks/pbt-stop.sh
# ──────────────────────────────────────────
install_stop_hook() {
  local dir="${CURSOR_DIR}/hooks"
  local file="${dir}/pbt-stop.sh"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'HOOK_EOF'
#!/bin/bash
#
# Cursor stop hook — Plan-Build-Test dashboard sync
#
# Fires after every agent task completes. Reads the last log entry from
# ~/.pbt-log.jsonl and POSTs it to the centralized Vercel dashboard.
# Fire-and-forget: silent failure, non-blocking.

set -uo pipefail

PBT_DASHBOARD_URL="${PBT_DASHBOARD_URL:-https://dashboard-indol-phi-65.vercel.app}"
PBT_API_TOKEN="${PBT_API_TOKEN:-}"
PBT_VERCEL_BYPASS="${PBT_VERCEL_BYPASS:-B7lEFKHRm7O3yM3BTIbs0F3RKrzWWawX}"
LOG_FILE="$HOME/.pbt-log.jsonl"

[ -f "$LOG_FILE" ] || exit 0
LAST_LINE=$(tail -1 "$LOG_FILE" 2>/dev/null)
[ -z "$LAST_LINE" ] && exit 0

PAYLOAD=$(echo "$LAST_LINE" | python3 -c "
import sys, json, os
try:
    entry = json.loads(sys.stdin.read())
    if not entry.get('user'):
        entry['user'] = os.environ.get('USER', 'unknown')
    print(json.dumps(entry))
except:
    sys.exit(1)
" 2>/dev/null) || exit 0

CURL_ARGS=(-s -X POST "${PBT_DASHBOARD_URL}/api/log"
  -H "Content-Type: application/json"
  --connect-timeout 5
  --max-time 10)

[ -n "$PBT_API_TOKEN" ] && CURL_ARGS+=(-H "Authorization: Bearer $PBT_API_TOKEN")
[ -n "$PBT_VERCEL_BYPASS" ] && CURL_ARGS+=(-H "x-vercel-protection-bypass: $PBT_VERCEL_BYPASS")

echo "$PAYLOAD" | curl "${CURL_ARGS[@]}" -d @- >/dev/null 2>&1 &

exit 0
HOOK_EOF

  chmod +x "$file"
  green "✓ Stop hook installed → ${file}"
  installed+=("hooks/pbt-stop.sh")
}

# ──────────────────────────────────────────────────
# 6. Log helper: ~/.cursor/hooks/pbt-log.sh
# ──────────────────────────────────────────────────
install_log_helper() {
  local dir="${CURSOR_DIR}/hooks"
  local file="${dir}/pbt-log.sh"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'LOGHELPER_EOF'
#!/bin/bash
# PBT log helper — appends a single JSON line from stdin to the PBT log.
# Called by the agent via: echo '{"ts":"..."}' | ~/.cursor/hooks/pbt-log.sh
# Using a fixed-name script lets Cursor IDE allowlist it once.
read -r -t 5 line || true
[ -n "$line" ] && printf '%s\n' "$line" >> "$HOME/.pbt-log.jsonl"
LOGHELPER_EOF

  chmod +x "$file"
  green "✓ Log helper installed → ${file}"
  installed+=("hooks/pbt-log.sh")
}

# ───────────────────────────────────────────────────────────────
# 7. CLI config: ~/.cursor/cli-config.json (MERGE permissions)
# ───────────────────────────────────────────────────────────────
install_cli_config() {
  local file="${CURSOR_DIR}/cli-config.json"
  backup_if_exists "$file"

  local result
  result=$(python3 -c "
import json, os

config_path = os.path.expanduser('~/.cursor/cli-config.json')

pbt_permissions = [
    'Shell(printf ** >> **pbt-log.jsonl)',
    'Shell(echo ** >> **pbt-log.jsonl)',
    'Shell(cat **/log-schema.md)',
    'Shell(tail **pbt-log.jsonl**)',
]

if os.path.exists(config_path):
    try:
        with open(config_path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        data = {}
else:
    data = {}

if 'permissions' not in data:
    data['permissions'] = {}
if 'allow' not in data['permissions']:
    data['permissions']['allow'] = []

existing = set(data['permissions']['allow'])
added = []
for perm in pbt_permissions:
    if perm not in existing:
        data['permissions']['allow'].append(perm)
        added.append(perm)

if not added:
    print('SKIPPED')
else:
    with open(config_path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print('INSTALLED')
")

  if [ "$result" = "SKIPPED" ]; then
    green "✓ cli-config.json — PBT permissions already present (no changes)"
    skipped+=("cli-config.json (permissions already set)")
  else
    green "✓ cli-config.json — PBT log permissions added"
    installed+=("cli-config.json")
  fi
}

# ──────────────────────────────
# Main
# ──────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Plan-Build-Test (PBT) Installer            ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  install_rule
  install_skill
  install_log_schema
  install_hooks_json
  install_stop_hook
  install_log_helper
  install_cli_config

  echo ""
  echo "────────────────────────────────────────────────"
  echo ""
  green "Installed ${#installed[@]} file(s):"
  for f in "${installed[@]}"; do
    echo "  ~/.cursor/${f}"
  done

  if [ ${#skipped[@]} -gt 0 ]; then
    echo ""
    yellow "Skipped (already present):"
    for f in "${skipped[@]}"; do
      echo "  ${f}"
    done
  fi

  echo ""
  echo "────────────────────────────────────────────────"
  echo ""
  green "What to do next:"
  echo "  1. Restart Cursor (Cmd+Shift+P → Reload Window)"
  echo "  2. Open any project and use Agent mode"
  echo "  3. Your first coding prompt will trigger P.B.T."
  echo "  4. Log entries auto-POST to the team dashboard"
  echo ""
}

main
