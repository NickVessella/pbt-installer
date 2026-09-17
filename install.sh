#!/bin/bash
#
# Plan-Build-Test (PBT) Installer — Cursor, Claude Code, Claude Design
#
# Interactive menu on /dev/tty when no host flags (works with curl|bash).
# Design: prepares a ZIP for Customize > Skills upload (last click still required).
#
# Usage:
#   bash install.sh
#   curl -fsSL https://cdn.jsdelivr.net/gh/NickVessella/pbt-installer@main/install.sh | bash
#   bash install.sh --with-claude | --all | --design-only | …
#
# Exclusive flags select hosts (multiple *-only combine).
# --with-claude / --with-design add Code/Design. Default dual: --with-claude. Triple: --all.

set -euo pipefail

CURSOR_DIR="$HOME/.cursor"
CLAUDE_DIR="$HOME/.claude"
PBT_DIR="$HOME/.pbt"
BACKUP_TS=$(date +%Y%m%d%H%M%S)

INSTALL_CURSOR=0
INSTALL_CLAUDE=0
INSTALL_DESIGN=0
HOSTS_SET=0
HAD_EXCLUSIVE=0
HAD_HOST_FLAG=0
SKIP_MENU=0

for arg in "$@"; do
  case "$arg" in
    --cursor-only)
      if [ "$HOSTS_SET" -eq 0 ]; then
        INSTALL_CURSOR=0; INSTALL_CLAUDE=0; INSTALL_DESIGN=0
        HOSTS_SET=1
      fi
      INSTALL_CURSOR=1
      HAD_EXCLUSIVE=1
      HAD_HOST_FLAG=1
      ;;
    --claude-only)
      if [ "$HOSTS_SET" -eq 0 ]; then
        INSTALL_CURSOR=0; INSTALL_CLAUDE=0; INSTALL_DESIGN=0
        HOSTS_SET=1
      fi
      INSTALL_CLAUDE=1
      HAD_EXCLUSIVE=1
      HAD_HOST_FLAG=1
      ;;
    --design-only)
      if [ "$HOSTS_SET" -eq 0 ]; then
        INSTALL_CURSOR=0; INSTALL_CLAUDE=0; INSTALL_DESIGN=0
        HOSTS_SET=1
      fi
      INSTALL_DESIGN=1
      HAD_EXCLUSIVE=1
      HAD_HOST_FLAG=1
      ;;
    --all)
      if [ "$HOSTS_SET" -eq 0 ]; then
        INSTALL_CURSOR=0; INSTALL_CLAUDE=0; INSTALL_DESIGN=0
        HOSTS_SET=1
      fi
      INSTALL_CURSOR=1
      INSTALL_CLAUDE=1
      INSTALL_DESIGN=1
      HAD_EXCLUSIVE=1
      HAD_HOST_FLAG=1
      ;;
    --with-claude)
      INSTALL_CLAUDE=1
      if [ "$HAD_EXCLUSIVE" -eq 0 ]; then
        INSTALL_CURSOR=1
      fi
      HAD_HOST_FLAG=1
      ;;
    --with-design)
      INSTALL_DESIGN=1
      if [ "$HAD_EXCLUSIVE" -eq 0 ]; then
        INSTALL_CURSOR=1
      fi
      HAD_HOST_FLAG=1
      ;;
    -y|--yes)
      SKIP_MENU=1
      ;;
    -h|--help)
      cat <<'HELP'
Usage: bash install.sh [flags]

  (no flags)          Interactive menu on /dev/tty; else Cursor only
  --cursor-only       Cursor + shared ~/.pbt
  --claude-only       Claude Code + shared ~/.pbt
  --design-only       Prepare Design skill ZIP (upload still required)
  --all               Cursor + Claude Code + Design ZIP
  --with-claude       Add Claude Code (with Cursor unless a *-only cleared it)
  --with-design       Add Design ZIP prep
  --claude-only --design-only
                      Code + Design (no Cursor)
  -y, --yes           Skip menu; Cursor only if no host flags

Exclusive flags select hosts (multiple *-only combine).
--with-claude / --with-design add Code/Design. Default dual: --with-claude. Triple: --all.
HELP
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

apply_menu_choice() {
  case "$1" in
    1)
      INSTALL_CURSOR=1; INSTALL_CLAUDE=0; INSTALL_DESIGN=0
      ;;
    2)
      INSTALL_CURSOR=0; INSTALL_CLAUDE=1; INSTALL_DESIGN=0
      ;;
    3)
      INSTALL_CURSOR=0; INSTALL_CLAUDE=0; INSTALL_DESIGN=1
      ;;
    4)
      INSTALL_CURSOR=1; INSTALL_CLAUDE=1; INSTALL_DESIGN=1
      ;;
    5)
      INSTALL_CURSOR=1; INSTALL_CLAUDE=1; INSTALL_DESIGN=0
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

prompt_hosts_if_needed() {
  if [ "$HAD_HOST_FLAG" -eq 1 ]; then
    return 0
  fi
  if [ "$SKIP_MENU" -eq 1 ]; then
    INSTALL_CURSOR=1
    INSTALL_CLAUDE=0
    INSTALL_DESIGN=0
    return 0
  fi
  # curl|bash has no TTY on stdin; menu must use /dev/tty. If it is missing
  # or not usable (CI, some sandboxes), default to Cursor without hanging.
  if ! ( : > /dev/tty ) 2>/dev/null; then
    INSTALL_CURSOR=1
    INSTALL_CLAUDE=0
    INSTALL_DESIGN=0
    return 0
  fi

  print_menu() {
    {
      echo "Install PBT for which host(s)?"
      echo "  1) Cursor"
      echo "  2) Claude Code only"
      echo "  3) Claude Design (ZIP prep — upload still required)"
      echo "  4) All (Cursor + Code + Design)"
      echo "  5) Cursor + Claude Code"
      printf "Choose [1]: "
    } > /dev/tty
  }

  choice=""
  print_menu
  # shellcheck disable=SC2162
  IFS= read -r choice < /dev/tty || true
  choice=$(printf '%s' "$choice" | tr -d '[:space:]')
  if [ -z "$choice" ]; then
    choice=1
  fi
  if ! apply_menu_choice "$choice"; then
    {
      echo "Invalid choice. Try again."
      printf "Choose [1]: "
    } > /dev/tty
    IFS= read -r choice < /dev/tty || true
    choice=$(printf '%s' "$choice" | tr -d '[:space:]')
    if [ -z "$choice" ] || ! apply_menu_choice "$choice"; then
      apply_menu_choice 1
      echo "Defaulting to Cursor." > /dev/tty
    fi
  fi
}

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

`~/.cursor/skills/plan-build-test/SKILL.md` (log via `~/.pbt/bin/pbt-log.sh`)

Read that file at the start of any coding task in this session if you haven't already. It is not optional and applies across all projects.

## Non-negotiables (minimum enforcement without reading the file)

1. **First output line** of every coding response MUST be the triage label — before any tool call, before reading any file:
   - `P.B.T. Trivial: make the change, no plan needed`
   - `P.B.T. Small Scope: abbreviated plan, then build and test`
   - `P.B.T. Complex: full plan-build-test workflow`
   - `P.B.T. Investigative: spike first, then plan-build-test`

2. **Last action** of every task is logging. Pipe a single-line JSON entry to the log helper:

   ```bash
   echo '{"ts":"...","triage":"...","task":"..."}' | ~/.pbt/bin/pbt-log.sh
   ```

   **Never append to `~/.pbt-log.jsonl` directly** — not with `>>`, not with `printf`, not with an editor. The helper validates and normalizes all 27 fields; a direct write skips that and corrupts the log. A nonzero exit means the entry was quarantined rather than logged, and the reason is on stderr — say so instead of reporting a clean "done". The task is NOT complete until the entry is written.

3. **Log schema** lives at `~/.pbt/log-schema.md` — use the exact field names defined there. All 27 fields belong in the entry, not just the required three. In particular `user`, `project` and `language` are routinely omitted and silently become `"unknown"`, which makes the task unattributable in reporting.

4. **The triage label is response text, not data.** The `P.B.T. ` prefix belongs on the first line of your reply. The `triage` log field takes the bare value — `"Complex"`, never `"P.B.T. Complex"`. Copying the label verbatim into the field is what corrupted three entries in August 2026.
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
description: Use when the user asks for code changes, new features, bug fixes, refactoring, edits, style changes, or any implementation work. Also use when the user reports an error or broken behavior after a previous edit.
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
> **⛔ Anti-pattern: reading code to reduce triage uncertainty.** A wrong tier is cheap — escalate mid-task with a one-line note. A pre-triage tool call is unrecoverable: you cannot un-read the code.
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

**Common pre-triage rationalizations — all are violations:**

| Excuse | Reality |
|--------|---------|
| "I need to find the file first to understand the task." | File location is irrelevant to triage. Classify from what the user asked, not what the code looks like. |
| "Let me just quickly check what's already there." | There is no such thing as a quick pre-check. Any tool call before the label is a violation. |
| "The request is vague — I need more context before I can classify." | Vague request → ask the user to clarify using `AskQuestion`. Do NOT read code to resolve vagueness. |
| "I'll output the label right after this one search." | No. Label first. One pre-triage tool call is the same violation as ten. |

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

**Common build-before-plan rationalizations — all are violations:**

| Excuse | Reality |
|--------|---------|
| "The user is blocked — I'll explain my approach as I go." | Urgency doesn't remove the requirement. A plan written under pressure is faster than code that needs a rewrite. |
| "I'll summarize what I did at the end — that's essentially a plan." | Post-build summaries describe what happened. Plans constrain what will happen. They are not equivalent. |
| "The approach is obvious — documenting it would be overhead." | If it's obvious, the plan takes 2 minutes. If it surprises you mid-build, the plan would have caught it. |
| "I'll just start and adjust as I go." | This is exactly what Complex tier exists to prevent. The plan is a pre-build checklist, not a post-build report. |

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
1. **Build gate (mandatory).** Run the project's compile/build command (`tsc --noEmit`, `npm run build`, or equivalent) on every edit — including Trivial fixes. If it fails, fix before continuing. This is not optional. A lint-only check does not replace a build pass; linters do not catch TDZ errors, unclosed JSX, or missing imports that a full compile does. A clean build is also necessary but not sufficient — type-only imports, dead branches, and string-literal references all evade compile-time checking. For bulk renames or symbol swaps, see the Task-shape recipes below.
2. **Runtime gate (mandatory for web projects).** After the build passes, confirm the app actually serves a page. Skip only for libraries, CLI tools, or projects with no running server.
   - If a dev server is running (check terminal output or `lsof -i :3000` / equivalent port), hit the main route with `curl -s -o /dev/null -w '%{http_code}' http://localhost:<port>` and confirm a 2xx response.
   - If the response is not 2xx, or the body contains error signatures (`Server Error`, `Cannot find module`, `Internal Server Error`, `502`, `503`, Cloudflare error tokens), the gate fails.
   - **Stale cache recovery:** If the error matches a module-not-found pattern (e.g., `Cannot find module './XXX.js'`), delete the build cache directory (`.next`, `dist`, `.cache`, or equivalent), restart the dev server, and re-check. This catches `.next` desync from running `npm run build` while the dev server is active.
   - If no dev server is running and the project is a web app, start it, wait for the ready signal, run the check, then stop it (or leave it running if the user's workflow expects it).
   - **Stylesheet sanity check:** After confirming a 2xx response, verify stylesheet links resolve — a page can return 200 OK with completely broken styles. Script: `~/.cursor/skills/plan-build-test/scripts/step4-gates.md`. If any stylesheet returns non-200, the runtime gate fails.
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
   - Any recipes from "Task-shape recipes" below that match this change

   **Task-shape recipes** — mandatory test cases by task shape. When the change matches one of these shapes, the listed verification is required in addition to the generic cases above. Build success is necessary but not sufficient for these shapes.

   - **Pure function on key/identifier arrays** (sort, filter, dedupe, diff, reorder, `indexOf`-based lookup): include at least one test with duplicate keys. Functions whose signature is `(keys: K[]) => ...` have a collision failure mode by default — `indexOf` returns only the first match, `Set`-based dedupe drops repeats, stable-sort assumptions break, and so on. Generic happy / empty / null cases will not surface this.
   - **Bulk symbol rename / find-and-replace / framework swap**: after the edit, run `rg <old-symbol>` (or equivalent) across the source tree and confirm zero hits in non-generated files. The build gate does not catch this — type-only imports are tree-shaken silently, and dead branches, dynamic `require()` strings, and string-literal references all evade compile-time checking.

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

**Common log-skipping rationalizations — all are violations:**

| Excuse | Reality |
|--------|---------|
| "The task is done — the code change is made." | Done means the log is written. Code change + no log = task 90% complete. |
| "It was only a quick rename, nothing worth logging." | Every completed task logs, including Trivial. Especially Trivial — they're the ones most likely to skip it. |
| "We're wrapping up the session, I'll log next time." | There is no next time. The log is the last action of this task, before anything else. |
| "I summarized in my response — that's enough." | The response is for the user. The log entry is for the system. They serve different purposes. |

**⛔ MANDATORY: Re-read the schema file before writing the log.** Do not write the log from memory. Field names have exact spellings, and every one of the 27 fields belongs in the entry.

The helper validates the **full schema** and repairs what it can rather than rejecting: a missing field gets its default, `files_changed: ["a.tsx","b.tsx"]` becomes `2`, an alias like `files_touched` is mapped to the real field, and an off-schema key such as `outcome` or `result` is moved into `notes` as a `[pbt-salvage]` block. It prints on stderr whatever it corrected.

**Do not treat that as licence to be sloppy.** Normalization is a safety net for the log, not a substitute for a correct entry — a defaulted field records nothing, and a salvaged key means a real metric ended up as free text. If stderr shows corrections, the payload was wrong; fix it next time. Only four things are unrecoverable and quarantine the entry outright: unparseable JSON, no `ts`, no `task`, and a `triage` that isn't one of the four values.

**`language` is the one attribution field only you can supply.** Nothing else knows what you changed, so if you omit it the entry is permanently unattributable by language — as of 2026-09-17 that accounts for 238 entries, every single one of the log's unattributable records. Always set it to the primary language of the change (`ts`, `py`, `css`, `md`, `sh`, …).

`user` and `project` are now derived by the helper — `whoami`, and the basename of the git repo root — because they are knowable at write time and were being dropped on 15–18% of entries. **Still set them when you know them:** the helper only fills a gap, never overrides you, and it cannot derive `project` outside a git repo. When it has to step in it records `_derived_by_helper` on the entry, and the weekly audit reports that as emitter sloppiness rather than a clean payload.

**The triage label is response text, not data.** The `P.B.T. ` prefix belongs on the first line of your reply; the `triage` field takes the bare value (`"Complex"`, never `"P.B.T. Complex"`).

```bash
cat ~/.pbt/log-schema.md
```

Then:

1. Build the JSON payload using ONLY the field names in the schema
2. Pipe the JSON line to the log helper script:
   ```bash
   echo '{"ts":"...","user":"..."}' | ~/.pbt/bin/pbt-log.sh
   ```
   **⛔ Do NOT use `printf` or `echo` with `>>` to write directly to `~/.pbt-log.jsonl`.** Direct writes trigger an approval prompt in Cursor IDE on every task because the payload is unique each time. The helper script has a fixed name that can be allowlisted once.
3. If `$PBT_SLACK_WEBHOOK` is set, send to Slack per the reference file

If the pipe or curl command fails, note the failure to the user and move on — a logging failure should not block the user. But you must *attempt* it before declaring done.

**A nonzero exit from `pbt-log.sh` means the entry was quarantined, not logged.** The reason is on stderr. Tell the user, in one line, that the task is done but the log entry was rejected and why — do not report a clean "done". The entry is recoverable from `~/.pbt-log-quarantine.jsonl`.

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
# 4a. Step 4 gate scripts: ~/.cursor/skills/plan-build-test/scripts/step4-gates.md
# ─────────────────────────────────────────────────────
install_step4_gates() {
  local dir="${CURSOR_DIR}/skills/plan-build-test/scripts"
  local file="${dir}/step4-gates.md"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'GATES_EOF'
# Step 4 Gate Scripts

## Stylesheet sanity check

Run after confirming a 2xx response from the dev server. Verifies that every CSS file referenced in the page HTML actually resolves. A page can return 200 OK with completely broken styles — this catches the "CSS file 404" class of bugs that a status-code-only check misses.

```bash
curl -s http://localhost:<port> \
  | grep -oP '(?<=href=")[^"]*\.css[^"]*' \
  | while read href; do
      url=$(echo "$href" | grep -q '^http' && echo "$href" || echo "http://localhost:<port>$href")
      status=$(curl -s -o /dev/null -w '%{http_code}' "$url")
      [ "$status" != "200" ] && echo "FAIL: $href returned $status" && exit 1
    done
```

If any stylesheet returns non-200, the runtime gate fails.

GATES_EOF

  green "✓ Step 4 gates installed → ${file}"
  installed+=("skills/plan-build-test/scripts/step4-gates.md")
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
# 4b. Shared ~/.pbt (gated log + sync + schema)
# ──────────────────────────────────────────
install_shared_pbt() {
  local dir="$PBT_DIR"
  mkdir -p "${dir}/bin" "${dir}/lib"

  # The schema module is the single source of truth for the 27-field contract.
  # pbt-log.sh, pbt-lint.py, pbt_post.py and the Monday audit all import it, so
  # that validation logic exists once rather than in four hand-copied places.
  local schema_py="${dir}/lib/pbt_schema.py"
  backup_if_exists "$schema_py"
  cat > "$schema_py" <<'PBT_SCHEMA_PY_EOF'
"""PBT log schema — the single source of truth.

Consumed by:
  - pbt-log.sh      (write-time gate: normalize-then-append)
  - pbt-repair.py   (one-time history backfill)
  - the Monday audit (read-time reporting)

Canonical schema mirrors ~/.pbt/log-schema.md. If that file changes, change
this one in the same commit — they are the same contract in two formats.

Design principle: NORMALIZE, don't reject. A missing integer becomes 0; a
`files_changed` that arrived as a list of filenames becomes the list's length
with the filenames preserved. Only entries whose meaning cannot be recovered
(unparseable JSON, no `ts`, no `task`, unrecognizable `triage`) go to
quarantine. A write path that throws work away is a write path people bypass.

Second principle: NEVER silently change a value. Every coercion, default-fill
and dropped key is recorded — in the `changes` list for the caller, and for
anything carrying data, in a machine-readable salvage block appended to
`notes`. If a number in this log is wrong, the original is recoverable.
"""

import datetime as _dt
import json as _json
import re as _re

TRIAGE_VALUES = ("Trivial", "Small Scope", "Complex", "Investigative")

# Junk prefixes observed on `triage` in the wild (lines 1089/1122/1144,
# 2026-08-19..25).
TRIAGE_PREFIXES = ("p.b.t.", "pbt")

# Legacy / short forms seen in Feb-May 2026 entries.
TRIAGE_LEGACY = {
    "quick": "Trivial",
    "small": "Small Scope",
    "investigate": "Investigative",
    "investigation": "Investigative",
}

# Off-schema keys whose meaning is unambiguous. Mapped to the real field rather
# than merely salvaged into notes, so the metric is not lost to free text.
ALIAS_MAP = {
    "timestamp": "ts",
    "tier": "triage",
    "files_touched": "files_changed",
    "goal": "task",
    "tests_added": "tests_written",
    "escalation_count": None,   # known-but-unmappable: salvage only
}

SALVAGE_TAG = "[pbt-salvage]"

# Fields whose absence is real information loss rather than routine omission.
# When one of these gets defaulted, the entry records it so the audit can
# measure emitter quality straight from the log.
#
# Why this exists: normalizing turned a loud failure into a quiet one. Before
# the gate, a missing `project` was a schema violation the audit shouted about;
# now it silently becomes "unknown" and the entry is technically valid. On
# 2026-09-16, 3 of 7 new entries had no project, language or user, and nothing
# in the report would have said so. Defaulting the routine fields
# (`visual_issues_found=0` and friends) is not worth recording; losing
# attribution is.
ATTRIBUTION_FIELDS = ("user", "project", "language")

INT, BOOL, STR, LIST = "int", "bool", "str", "list"

# field -> (type, default, nullable)
SCHEMA = {
    "ts":                   (STR,  None,      False),
    "user":                 (STR,  "unknown", False),
    "project":              (STR,  "unknown", False),
    "triage":               (STR,  None,      False),
    "task":                 (STR,  None,      False),
    "files_changed":        (INT,  0,         False),
    "files_created":        (INT,  0,         False),
    "tests_written":        (INT,  0,         False),
    "tests_fixed":          (INT,  0,         False),
    # Nullable on purpose. Defaulting an absent value to `true` would assert
    # that tests passed for an entry that never said so — and the Monday audit
    # computes pass rate from this field, so 92 backfilled `true`s would have
    # silently inflated it. `null` means "not recorded" and is excluded from
    # the rate, which is the honest reading.
    "all_tests_passed":     (BOOL, None,      True),
    "risks_identified":     (INT,  0,         False),
    "risks_mitigated":      (INT,  0,         False),
    "risks_out_of_scope":   (INT,  0,         False),
    "risks_ask_user":       (INT,  0,         False),
    "stopped_to_ask_user":  (BOOL, False,     False),
    "plan_deviations":      (INT,  0,         False),
    "pre_existing_issues":  (LIST, [],        False),
    "language":             (STR,  "unknown", False),
    "visual_check":         (BOOL, False,     False),
    "visual_issues_found":  (INT,  0,         False),
    "escalated":            (BOOL, False,     False),
    "escalated_from":       (STR,  None,      True),
    "spiked":               (BOOL, False,     False),
    "spike_resolved":       (BOOL, False,     False),
    "mid_plan_spike":       (BOOL, False,     False),
    "duration_min":         (INT,  None,      True),
    "notes":                (STR,  None,      True),
}

FIELD_ORDER = list(SCHEMA.keys())
REQUIRED = ("ts", "triage", "task")

# Sanity bounds. Outside these a value is almost certainly a units or parsing
# error rather than a real measurement, so it is flagged (not silently fixed).
MAX_COUNT = 100_000
MAX_DURATION_MIN = 60 * 24 * 14  # two weeks

_DATE_ONLY = _re.compile(r"^\d{4}-\d{2}-\d{2}$")
_BASIC_OFFSET = _re.compile(r"([+-])(\d{2})(\d{2})$")
_FRACTIONAL = _re.compile(r"\.(\d{7,})")          # >6 fractional digits
_LEADING_INT = _re.compile(r"^\s*(-?\d+)")
_ISO_SHAPE = _re.compile(
    r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?"
    r"(Z|[+-]\d{2}:?\d{2})?$"
)


# --------------------------------------------------------------------------
# JSON loading that notices duplicate keys
# --------------------------------------------------------------------------

def loads(raw):
    """json.loads, but duplicate keys are reported instead of silently lost.

    Returns (obj, duplicates) where duplicates maps key -> [shadowed values].
    """
    dupes = {}

    def hook(pairs):
        seen = {}
        for key, value in pairs:
            if key in seen:
                dupes.setdefault(key, []).append(seen[key])
            seen[key] = value
        return seen

    return _json.loads(raw, object_pairs_hook=hook), dupes


# --------------------------------------------------------------------------
# timestamps
# --------------------------------------------------------------------------

def _parse_dt(text):
    """Tolerant ISO-8601 parse. Returns datetime or None.

    Independent of the host Python's `fromisoformat` capabilities so that
    whether an entry is accepted never depends on which python3 is on PATH.
    """
    candidate = _BASIC_OFFSET.sub(r"\1\2:\3", text.strip())
    # fromisoformat before 3.11 rejects 'Z' and >6 fractional digits.
    candidate = _FRACTIONAL.sub(lambda m: "." + m.group(1)[:6], candidate)
    normalized = candidate[:-1] + "+00:00" if candidate.endswith("Z") else candidate
    try:
        return _dt.datetime.fromisoformat(normalized)
    except (ValueError, OverflowError):
        return None


def normalize_ts(value):
    """Return (canonical_ts, note_or_None); canonical_ts is None if unusable."""
    if not isinstance(value, str) or not value.strip():
        return None, "ts is not a string: %r" % (value,)
    raw = value.strip()

    if _DATE_ONLY.match(raw):
        return raw + "T00:00:00Z", "original ts was date-only: %s" % raw

    if not _ISO_SHAPE.match(_BASIC_OFFSET.sub(r"\1\2:\3", raw)):
        return None, "ts is not an ISO-8601 datetime: %r" % (value,)
    if _parse_dt(raw) is None:
        return None, "ts is not a valid datetime: %r" % (value,)

    canonical = _BASIC_OFFSET.sub(r"\1\2:\3", raw)
    return canonical, None


def is_iso_datetime(value):
    if not isinstance(value, str) or _DATE_ONLY.match(value.strip()):
        return False
    return normalize_ts(value)[0] is not None


def ts_sort_key(value):
    """Timezone-aware sort key; naive timestamps are assumed UTC."""
    parsed = _parse_dt(value) if isinstance(value, str) else None
    if parsed is None:
        return _dt.datetime.min.replace(tzinfo=_dt.timezone.utc)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed


# --------------------------------------------------------------------------
# coercion
# --------------------------------------------------------------------------

def _coerce_int(value):
    """Return (int_value, salvage_or_None) or (None, reason) if uncoercible."""
    if isinstance(value, bool):
        return int(value), None
    if isinstance(value, int):
        return value, None
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            return None, "non-finite number"
        rounded = int(round(value))
        return rounded, (None if rounded == value else value)
    if isinstance(value, list):
        items = [x for x in value if str(x).strip()]
        return len(items), (items if items else None)
    if isinstance(value, dict):
        return None, value
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return 0, None
        try:
            return int(raw), None
        except ValueError:
            pass
        # A leading number with trailing prose: "12 files" -> 12.
        match = _LEADING_INT.match(raw)
        if match:
            return int(match.group(1)), raw
        # Filenames where a count was expected. A single path counts as 1 —
        # returning 0 for "viteConfig.test.ts" would understate real work.
        # Requires a path-ish signal so that prose ("about an hour") stays
        # uncoercible rather than being silently counted as one of something.
        if any(ch in raw for ch in ",/\\."):
            parts = [p.strip() for p in _re.split(r"[,\n]", raw) if p.strip()]
            if parts:
                return len(parts), parts if len(parts) > 1 else raw
        return None, raw
    if value is None:
        return 0, None
    return None, value


_TRUE = {"true", "yes", "1", "pass", "passed", "success", "ok"}
_FALSE = {"false", "no", "0", "fail", "failed", "failure", "error"}


def _coerce_bool(value):
    """Return (bool, salvage_or_None) or (None, reason)."""
    if isinstance(value, bool):
        return value, None
    if isinstance(value, int) and value in (0, 1):
        return bool(value), None
    if isinstance(value, str):
        low = value.strip().lower()
        if low in _TRUE:
            return True, None
        if low in _FALSE:
            return False, None
    return None, value


def _coerce_triage(value):
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    if not isinstance(value, str):
        return None
    # Collapse internal whitespace, drop trailing punctuation.
    raw = _re.sub(r"\s+", " ", value).strip().strip(".,;:!-").strip()
    if not raw:
        return None

    lowered = raw.lower()
    for prefix in TRIAGE_PREFIXES:
        if lowered.startswith(prefix):
            raw = raw[len(prefix):].strip().strip(".").strip()
            lowered = raw.lower()
            break

    for valid in TRIAGE_VALUES:
        if lowered == valid.lower():
            return valid
    if lowered in TRIAGE_LEGACY:
        return TRIAGE_LEGACY[lowered]
    return None


# --------------------------------------------------------------------------
# normalize
# --------------------------------------------------------------------------

def _append_salvage(notes, payload):
    """Append a machine-readable salvage block to a notes string."""
    if not payload:
        return notes
    try:
        # Compact separators so this matches JSON.stringify byte-for-byte.
        # The dashboard normalizes with a JS port generated from this module,
        # and Python's default ", "/": " spacing made the two emit different
        # `notes` strings for identical input — indistinguishable from a real
        # divergence when comparing the two implementations.
        blob = _json.dumps(payload, ensure_ascii=False, default=str,
                           separators=(",", ":"))
    except Exception:
        blob = _json.dumps({"unserializable": str(payload)[:500]})
    block = "%s %s" % (SALVAGE_TAG, blob)
    return ("%s %s" % (notes, block)) if notes else block


def has_salvage(entry):
    return isinstance(entry.get("notes"), str) and SALVAGE_TAG in entry["notes"]


def normalize(entry, duplicates=None):
    """Normalize one parsed entry against the schema.

    Returns (normalized_dict_or_None, changes, fatal_problems).
    Non-empty fatal_problems means the entry must be quarantined.
    """
    changes, fatal, salvage = [], [], {}

    if not isinstance(entry, dict):
        return None, changes, ["body must be a JSON object"]

    entry = dict(entry)

    # --- fold known aliases onto their real fields first -------------------
    for alias, target in ALIAS_MAP.items():
        if alias not in entry:
            continue
        value = entry.pop(alias)
        if target and target not in entry:
            entry[target] = value
            changes.append("alias %s -> %s" % (alias, target))
        else:
            salvage[alias] = value
            changes.append("alias %s salvaged (%s already set)" % (alias, target))

    if duplicates:
        salvage["_duplicate_keys"] = duplicates
        changes.append("duplicate JSON keys shadowed: %s" % sorted(duplicates))

    # --- triage (fatal) ---------------------------------------------------
    triage = _coerce_triage(entry.get("triage"))
    if triage is None:
        fatal.append("missing or unrecognizable triage: %r" % (entry.get("triage"),))
    elif triage != entry.get("triage"):
        changes.append("triage %r -> %r" % (entry.get("triage"), triage))
        # Recorded on the entry, not just on stderr. The `P.B.T. ` prefix comes
        # from the rules file's own mandate that the triage LABEL open every
        # response; an agent reusing that label verbatim as the field value
        # produces "P.B.T. Complex". Without this we cannot tell whether that
        # instruction is still leaking into the data.
        salvage["_triage_corrected_from"] = entry.get("triage")

    if not entry.get("task") or not str(entry.get("task")).strip():
        fatal.append("missing task")

    if fatal:
        return None, changes, fatal

    # --- ts (fatal if unparseable) ----------------------------------------
    ts_before = entry.get("ts")
    canonical_ts, ts_note = normalize_ts(ts_before)
    if canonical_ts is None:
        return None, changes, [ts_note]
    if canonical_ts != ts_before:
        changes.append("ts %r -> %r" % (ts_before, canonical_ts))
        entry["ts"] = canonical_ts
    if ts_note:
        # The ORIGINAL, captured before the replacement above. Reading
        # entry["ts"] here recorded the already-promoted value, which
        # round-tripped the very thing the marker exists to preserve.
        salvage["ts_original"] = ts_before

    # --- typed fields -----------------------------------------------------
    out = {}
    for field in FIELD_ORDER:
        kind, default, nullable = SCHEMA[field]
        blank_default = list(default) if isinstance(default, list) else default

        if field == "triage":
            out[field] = triage
            continue
        if field == "notes":
            continue  # written last, after salvage is complete

        if field not in entry:
            out[field] = blank_default
            changes.append("filled missing %s=%r" % (field, blank_default))
            if field in ATTRIBUTION_FIELDS:
                salvage.setdefault("_defaulted_attribution", []).append(field)
            continue

        value = entry[field]

        if value is None:
            if nullable:
                out[field] = None
            else:
                out[field] = blank_default
                changes.append("null %s -> %r" % (field, blank_default))
                if field in ATTRIBUTION_FIELDS:
                    salvage.setdefault("_defaulted_attribution", []).append(field)
            continue

        if kind == INT:
            new, extra = _coerce_int(value)
            if new is None:
                out[field] = blank_default
                salvage[field] = extra
                changes.append("uncoercible %s (salvaged) -> %r" % (field, blank_default))
            else:
                if isinstance(value, bool) or not isinstance(value, int) or new != value:
                    changes.append("%s %r -> %d" % (field, value, new))
                out[field] = new
                if extra is not None:
                    salvage[field] = extra

        elif kind == BOOL:
            new, extra = _coerce_bool(value)
            if new is None:
                out[field] = blank_default
                salvage[field] = extra
                changes.append("uncoercible %s=%r (salvaged) -> %r"
                               % (field, value, blank_default))
            else:
                if new is not value:
                    changes.append("%s %r -> %r" % (field, value, new))
                out[field] = new

        elif kind == LIST:
            if isinstance(value, list):
                out[field] = value
            elif isinstance(value, str) and value.strip():
                out[field] = [value.strip()]
                changes.append("%s str -> list" % field)
            else:
                out[field] = list(blank_default)
                salvage[field] = value
                changes.append("%s %r (salvaged) -> []" % (field, value))

        else:  # STR
            if isinstance(value, str):
                out[field] = value
            else:
                out[field] = str(value)
                salvage[field] = value
                changes.append("%s %r -> str" % (field, value))

    # --- unknown keys: preserve, never discard ----------------------------
    unknown = [k for k in entry if k not in SCHEMA]
    if unknown:
        for key in sorted(unknown):
            salvage[key] = entry[key]
        changes.append("off-schema keys salvaged: %s" % sorted(unknown))

    # --- notes last, carrying the salvage block ---------------------------
    notes_value = entry.get("notes")
    if notes_value is not None and not isinstance(notes_value, str):
        salvage["notes_original"] = notes_value
        notes_value = str(notes_value)
        changes.append("notes coerced to str")
    out["notes"] = _append_salvage(notes_value, salvage)

    return {k: out[k] for k in FIELD_ORDER}, changes, []


# --------------------------------------------------------------------------
# read-only reporting (used by the Monday audit)
# --------------------------------------------------------------------------

def violations(entry):
    """Report, rather than repair. The audit must tell the truth about disk."""
    problems = []
    if not isinstance(entry, dict):
        return ["not a JSON object"]

    for field in REQUIRED:
        if not entry.get(field):
            problems.append("missing required %s" % field)

    if entry.get("ts") and not is_iso_datetime(entry.get("ts")):
        problems.append("ts is not an ISO-8601 datetime: %r" % (entry.get("ts"),))

    if entry.get("triage") not in TRIAGE_VALUES:
        problems.append("invalid triage: %r" % (entry.get("triage"),))

    for field in FIELD_ORDER:
        if field not in entry:
            problems.append("missing field %s" % field)
            continue
        kind, _default, nullable = SCHEMA[field]
        value = entry[field]
        if value is None:
            if not nullable:
                problems.append("%s is null" % field)
            continue
        if kind == INT and (isinstance(value, bool) or not isinstance(value, int)):
            problems.append("%s is %s, expected int" % (field, type(value).__name__))
        elif kind == BOOL and not isinstance(value, bool):
            problems.append("%s is %s, expected bool" % (field, type(value).__name__))
        elif kind == LIST and not isinstance(value, list):
            problems.append("%s is %s, expected list" % (field, type(value).__name__))
        elif kind == STR and not isinstance(value, str):
            problems.append("%s is %s, expected str" % (field, type(value).__name__))

    for key in entry:
        if key not in SCHEMA:
            problems.append("off-schema key: %s" % key)

    problems.extend(implausible(entry))
    return problems


def salvage_payload(entry):
    """Parse the [pbt-salvage] block(s) back out of `notes`. {} if absent.

    Scans *every* occurrence of the tag and merges each one that decodes,
    rather than trusting the first. Two cases make that necessary, and both
    silently lost markers when this took the first match only:

      * an entry can legitimately carry more than one block — the repair
        appends a `ts_disambiguated_from` block after an existing one
      * the tag can appear inside the author's own `notes` prose, in which
        case the first match is not a JSON object at all and the real block
        sits further along

    Losing a block here would under-report the very emitter-quality signal
    these markers exist to provide, so it fails toward finding them.
    """
    notes = entry.get("notes")
    if not isinstance(notes, str) or SALVAGE_TAG not in notes:
        return {}

    merged = {}
    decoder = _json.JSONDecoder()
    position = notes.find(SALVAGE_TAG)
    while position != -1:
        blob = notes[position + len(SALVAGE_TAG):].lstrip()
        try:
            obj, _end = decoder.raw_decode(blob)
            if isinstance(obj, dict):
                merged.update(obj)
        except ValueError:
            pass
        position = notes.find(SALVAGE_TAG, position + len(SALVAGE_TAG))
    return merged


def emitter_quality(entries):
    """Measure how well the WRITE SIDE is behaving, not the log's validity.

    The log is guaranteed schema-clean by the gate, so `violations()` will
    report zero even when the emitter is producing near-empty payloads. This
    is the companion metric: it counts what the gate had to paper over.

    Returns a dict of counts plus the offending entries, for the audit's
    Attribution Quality section.
    """
    total = 0
    unattributed = []
    salvaged = []
    triage_corrected = []
    defaulted_attribution = []
    derived_by_helper = []
    unknown_by_field = {f: 0 for f in ATTRIBUTION_FIELDS}

    for entry in entries:
        if not isinstance(entry, dict):
            continue
        total += 1

        for field in ATTRIBUTION_FIELDS:
            if entry.get(field) == "unknown":
                unknown_by_field[field] += 1

        if any(entry.get(f) == "unknown" for f in ATTRIBUTION_FIELDS):
            unattributed.append(entry)

        payload = salvage_payload(entry)
        if payload:
            salvaged.append(entry)
        if "_triage_corrected_from" in payload:
            triage_corrected.append((entry, payload["_triage_corrected_from"]))
        if payload.get("_defaulted_attribution"):
            defaulted_attribution.append((entry, payload["_defaulted_attribution"]))
        if payload.get("_derived_by_helper"):
            derived_by_helper.append((entry, payload["_derived_by_helper"]))

    def pct(n):
        return round(100.0 * n / total, 1) if total else 0.0

    return {
        "total": total,
        # Per-field, because the union hides which field is the problem. On
        # 2026-09-17 the union read 17.8% and looked like a broad attribution
        # failure; it was `language` on all 238 entries, `project` on 204, and
        # `user` on none. `project` is the one that breaks analysis — a task
        # with no project drops out of every per-project report — so report the
        # fields separately and lead with project rather than the union.
        "unknown_by_field": unknown_by_field,
        "unknown_pct_by_field": {f: pct(n) for f, n in unknown_by_field.items()},
        # Retained as a rollup; prefer unknown_by_field when diagnosing.
        "unattributed": len(unattributed),
        "unattributed_pct": pct(len(unattributed)),
        "unattributed_entries": unattributed,
        "salvaged": len(salvaged),
        "salvaged_pct": pct(len(salvaged)),
        "triage_corrected": triage_corrected,
        "defaulted_attribution": defaulted_attribution,
        # The helper had to derive user/project because the emitter omitted
        # them. The stored value is correct, so this never shows up as a
        # violation — but a rising count means the emitter is degrading behind
        # a working safety net, which is exactly what a fallback can hide.
        "derived_by_helper": derived_by_helper,
    }


def implausible(entry):
    """Values that are schema-valid but almost certainly wrong."""
    notes = []
    if not isinstance(entry, dict):
        return notes
    for field, (kind, _d, _n) in SCHEMA.items():
        if kind != INT:
            continue
        value = entry.get(field)
        if not isinstance(value, int) or isinstance(value, bool):
            continue
        if value < 0:
            notes.append("%s is negative (%d)" % (field, value))
        elif field == "duration_min" and value > MAX_DURATION_MIN:
            notes.append("duration_min implausibly large (%d)" % value)
        elif field != "duration_min" and value > MAX_COUNT:
            notes.append("%s implausibly large (%d)" % (field, value))
    return notes
PBT_SCHEMA_PY_EOF
  green "✓ Shared schema module → ${schema_py}"
  installed+=(".pbt/lib/pbt_schema.py")

  # Self-healing lint: repairs anything that reached the log without going
  # through pbt-log.sh. Invoked from pbt-sync.sh on the task-stop hook.
  local lint_file="${dir}/bin/pbt-lint.py"
  backup_if_exists "$lint_file"
  cat > "$lint_file" <<'PBT_LINT_EOF'
#!/usr/bin/env python3
"""Self-healing lint for ~/.pbt-log.jsonl.

Runs from the task-stop hook (via pbt-sync.sh), so an entry that bypassed
pbt-log.sh is corrected within one task instead of surviving until Monday's
audit. Between 2026-08-19 and 2026-09-15 four such entries reached the log and
each one sat there for days.

Behaviour:
  * fixable entry  -> normalized in place, line count unchanged
  * unparseable    -> moved to ~/.pbt-log-quarantine.jsonl and the line removed
  * nothing wrong  -> exits silently having written nothing

Two things this is careful about:

1. `pbt-sync.sh` tracks dashboard progress with a LINE OFFSET in
   ~/.pbt-sync-state. Removing a line shifts every offset after it, which
   would make sync either re-post or skip entries. So removals are counted and
   the cursor is decremented by however many fell at or before it. Normalizing
   in place keeps the count stable and needs no adjustment.

2. It never rewrites the log unless something actually changed, so the common
   case costs one read.

Exit status is always 0 — a lint failure must not break the user's task.
"""

import json
import os
import sys

sys.path.insert(0, os.environ.get("PBT_LIB_DIR", os.path.expanduser("~/.pbt/lib")))

LOG = os.environ.get("PBT_LOG_FILE", os.path.expanduser("~/.pbt-log.jsonl"))
QUARANTINE = os.environ.get(
    "PBT_QUARANTINE_FILE", os.path.expanduser("~/.pbt-log-quarantine.jsonl")
)
STATE = os.environ.get("PBT_SYNC_STATE", os.path.expanduser("~/.pbt-sync-state"))
FINDINGS = os.environ.get(
    "PBT_LINT_FINDINGS", os.path.expanduser("~/.pbt-lint-findings.jsonl")
)


def main():
    try:
        import pbt_schema
        from pbt_schema import normalize
    except Exception:
        return 0  # validator unavailable; never break the task

    if not os.path.exists(LOG):
        return 0

    try:
        with open(LOG, encoding="utf-8", errors="surrogatepass") as fh:
            raw_lines = fh.read().splitlines()
    except OSError:
        return 0

    kept = []
    removed_indices = []
    findings = []
    dirty = False

    for idx, raw in enumerate(raw_lines, 1):
        stripped = raw.strip()
        if not stripped:
            removed_indices.append(idx)
            dirty = True
            continue

        try:
            entry, dupes = pbt_schema.loads(stripped)
        except Exception as ex:
            removed_indices.append(idx)
            findings.append({"line": idx, "action": "quarantined",
                             "reason": "parse_error: %s" % ex, "raw": stripped})
            dirty = True
            continue

        clean, changes, fatal = normalize(entry, dupes)
        if fatal:
            removed_indices.append(idx)
            findings.append({"line": idx, "action": "quarantined",
                             "reason": "; ".join(fatal), "raw": stripped})
            dirty = True
            continue

        rendered = json.dumps(clean, ensure_ascii=False)
        if rendered != stripped:
            dirty = True
            if changes:
                findings.append({"line": idx, "action": "normalized",
                                 "changes": changes})
        kept.append(rendered)

    if not dirty:
        return 0

    # --- rewrite atomically ------------------------------------------------
    tmp = LOG + ".lint-tmp"
    try:
        with open(tmp, "w", encoding="utf-8", errors="surrogatepass") as fh:
            for line in kept:
                fh.write(line + "\n")
        os.replace(tmp, LOG)
    except Exception:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return 0

    # --- keep the dashboard sync cursor pointing at the same entry ---------
    if removed_indices:
        try:
            cursor = int(open(STATE).read().strip())
        except (OSError, ValueError):
            cursor = None
        if cursor is not None:
            shift = sum(1 for i in removed_indices if i <= cursor)
            if shift:
                with open(STATE, "w") as fh:
                    fh.write(str(max(0, cursor - shift)))

    # --- record what happened, for Monday's audit -------------------------
    quarantine_records = [f for f in findings if f["action"] == "quarantined"]
    if quarantine_records:
        try:
            import datetime
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
            with open(QUARANTINE, "a", encoding="utf-8") as fh:
                for rec in quarantine_records:
                    fh.write(json.dumps({
                        "quarantined_at": stamp,
                        "reason": rec["reason"],
                        "source": "pbt-lint",
                        "entry": {"_raw": rec["raw"]},
                    }, ensure_ascii=False) + "\n")
        except OSError:
            pass

    if findings:
        try:
            import datetime
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
            with open(FINDINGS, "a", encoding="utf-8") as fh:
                for rec in findings:
                    rec["at"] = stamp
                    fh.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
        except OSError:
            pass
        sys.stderr.write(
            "pbt-lint: repaired %d log entr%s (%d quarantined); see %s\n"
            % (len(findings), "y" if len(findings) == 1 else "ies",
               len(quarantine_records), FINDINGS)
        )

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # never break the user's task
PBT_LINT_EOF
  chmod +x "$lint_file"
  green "✓ Self-healing log lint → ${lint_file}"
  installed+=(".pbt/bin/pbt-lint.py")

  local schema_file="${dir}/log-schema.md"
  backup_if_exists "$schema_file"
  cat > "$schema_file" <<'PBT_SCHEMA_EOF'
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

PBT_SCHEMA_EOF
  green "✓ Shared schema → ${schema_file}"
  installed+=(".pbt/log-schema.md")

  local log_file="${dir}/bin/pbt-log.sh"
  backup_if_exists "$log_file"
  cat > "$log_file" <<'PBT_LOG_EOF'
#!/bin/bash
# PBT log helper — appends a single JSON line from stdin to the PBT log.
# Called by the agent via: echo '{"ts":"..."}' | ~/.pbt/bin/pbt-log.sh
# Using a fixed-name script lets Cursor IDE allowlist it once.
#
# CHANGED 2026-09-15: validation moved from a 3-field check (ts / triage / task)
# to the full schema in ~/.pbt/lib/pbt_schema.py, and the behaviour changed from
# reject-or-append to NORMALIZE-then-append.
#
# Rationale: the old gate accepted 114 of the 118 malformed entries that
# accumulated in the log between Feb and Sep 2026, because it checked only three
# fields and explicitly allowed extra fields. Missing fields, `files_changed` as
# a list of filenames, and off-schema keys like `outcome` / `result` all passed
# straight through. Normalizing at the choke point fixes the class of problem
# rather than the instances.
#
# Entries are quarantined only when their meaning cannot be recovered
# (unparseable JSON, no ts, no task, unrecognizable triage). Everything else is
# repaired in place and appended, with the repairs reported on stderr so the
# agent — and the human reading the transcript — can see what was corrected.

set -uo pipefail

LOG_FILE="${PBT_LOG_FILE:-$HOME/.pbt-log.jsonl}"
QUARANTINE_FILE="${PBT_QUARANTINE_FILE:-$HOME/.pbt-log-quarantine.jsonl}"
LIB_DIR="${PBT_LIB_DIR:-$HOME/.pbt/lib}"

# Read ALL of stdin, not one line.
#
# The previous `read -r -t 5 line` had three data-loss bugs: pretty-printed
# JSON lost every field but the first line; a caller slower than 5s had its
# entry discarded with exit 0 and no trace at all; and a stall mid-write
# truncated the payload silently. `cat` has no timeout and no line limit, so a
# multi-line payload arrives whole and a slow writer blocks instead of
# vanishing.
line=$(cat)
[ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || exit 0

# Derive the attribution fields the agent keeps forgetting.
#
# `user` and `project` are mechanically knowable at write time — this script
# runs on the developer's machine, in the task's working directory — yet
# SKILL.md asked the MODEL to supply them, making them something an LLM can
# omit. It did, on 15-18% of entries (46% in one week), and each omission
# became "unknown", which silently drops the task out of every per-project and
# per-person report. As of 2026-09-17: 204 entries with no project.
#
# So the helper now works them out itself. A field you never have to supply is
# a field you cannot forget. Values the agent DID provide always win; these are
# a floor, not an override.
#
# `project` is taken only from a git root. Falling back to $(basename $PWD)
# would cheerfully record "nick.vessella" for anything run from $HOME, and a
# confidently wrong project is worse than a known-absent one.
#
# `language` is deliberately NOT derived: only the agent knows what it changed.
# It stays the emitter's responsibility and stays measured.
PBT_DERIVED_USER="$(whoami 2>/dev/null || true)"
PBT_DERIVED_PROJECT=""
if _git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  [ -n "$_git_root" ] && PBT_DERIVED_PROJECT="$(basename "$_git_root")"
fi
export PBT_DERIVED_USER PBT_DERIVED_PROJECT

# Normalize: clean JSON on stdout, "FATAL:<reason>" on stdout if unrecoverable,
# human-readable repair notes on stderr (which passes through to the caller).
#
# `python3 -I` runs isolated: it does NOT put the current working directory on
# sys.path. Without it, a `pbt_schema.py` sitting in whatever repo the agent
# happens to be working in would be imported instead of ours — arbitrary code
# execution on every log write, and a trivial way to corrupt the log.
normalized=$(printf '%s' "$line" | PBT_LIB_DIR="$LIB_DIR" python3 -I -c '
import sys, os, json

sys.path.insert(0, os.environ["PBT_LIB_DIR"])
raw = sys.stdin.read()

try:
    import pbt_schema
    from pbt_schema import normalize
except Exception as ex:
    # Never lose an entry because the validator is missing or broken. Degrade
    # to the old behaviour and say so loudly.
    sys.stderr.write("pbt-log.sh: validator unavailable (%s); appending unvalidated\n" % ex)
    sys.stdout.write(raw)
    sys.exit(0)

try:
    entry, dupes = pbt_schema.loads(raw)
except Exception as ex:
    sys.stdout.write("FATAL:parse_error: %s" % ex)
    sys.exit(0)

# Fill the derived attribution fields BEFORE normalizing, so the schema sees a
# real value rather than defaulting to "unknown". Only ever fills a gap — an
# agent-supplied value is never overwritten.
_derived = []
for _field, _env in (("user", "PBT_DERIVED_USER"), ("project", "PBT_DERIVED_PROJECT")):
    _value = os.environ.get(_env, "").strip()
    if _value and entry.get(_field) in (None, "", "unknown"):
        entry[_field] = _value
        _derived.append(_field)

clean, changes, fatal = normalize(entry, dupes)
if fatal:
    sys.stdout.write("FATAL:" + "; ".join(fatal))
    sys.exit(0)

# Record that the helper supplied these, not the agent. The value is correct
# either way, but the audit has to be able to tell a well-formed payload from
# one the safety net rescued — otherwise the fallback quietly hides a
# regression in the emitter, which is the same trap normalization itself set.
if _derived and clean is not None:
    _block = "%s %s" % (
        pbt_schema.SALVAGE_TAG,
        json.dumps({"_derived_by_helper": _derived}, separators=(",", ":")),
    )
    clean["notes"] = ("%s %s" % (clean["notes"], _block)) if clean.get("notes") else _block
    changes.append("derived %s from the environment" % ", ".join(_derived))
if changes:
    # Keep the report readable: list real corrections, summarize default-fills.
    fills = [c for c in changes if c.startswith("filled missing ")]
    fixes = [c for c in changes if not c.startswith("filled missing ")]
    parts = []
    if fixes:
        parts.append("corrected: " + "; ".join(fixes))
    if fills:
        names = [c.split()[2].split("=")[0] for c in fills]
        parts.append("defaulted %d absent field(s): %s" % (len(fills), ", ".join(names)))
    sys.stderr.write("pbt-log.sh: " + " | ".join(parts) + "\n")
sys.stdout.write(json.dumps(clean, ensure_ascii=False))
')

case "${normalized:-}" in
  FATAL:*) fail_reason="${normalized#FATAL:}" ;;
  "")      fail_reason="validation_failed" ;;
  *)
    printf '%s\n' "$normalized" >> "$LOG_FILE"
    exit 0
    ;;
esac

# Unrecoverable — quarantine. Never let the entry vanish with zero trace.
quarantine_payload=$(
  printf '%s' "$line" | PBT_QUARANTINE_REASON="$fail_reason" python3 -I -c '
import sys, json, os
from datetime import datetime, timezone

raw = sys.stdin.read()
try:
    entry = json.loads(raw)
except Exception:
    entry = {"_raw": raw}
rec = {
    "quarantined_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "reason": os.environ.get("PBT_QUARANTINE_REASON", "unknown"),
    "entry": entry,
}
print(json.dumps(rec, ensure_ascii=False))
' 2>/dev/null
)

if [ -n "$quarantine_payload" ] && printf '%s\n' "$quarantine_payload" >> "$QUARANTINE_FILE" 2>/dev/null; then
  printf 'pbt-log.sh: quarantined entry (%s)\n' "$fail_reason" >&2
  exit 1
fi

printf 'pbt-log.sh: quarantine write failed (%s); raw payload follows\n%s\n' "$fail_reason" "$line" >&2
exit 1
PBT_LOG_EOF
  chmod +x "$log_file"
  green "✓ Shared gated log helper → ${log_file}"
  yellow "  Note: re-run this installer on any machine that still has the old unguarded pbt-log.sh"
  installed+=(".pbt/bin/pbt-log.sh")

  local sync_file="${dir}/bin/pbt-sync.sh"
  backup_if_exists "$sync_file"
  cat > "$sync_file" <<'PBT_SYNC_EOF'
#!/bin/bash
#
# PBT dashboard sync — shared by Cursor stop hook and Claude Code Stop hook
#
# Syncs any log entries in
# ~/.pbt-log.jsonl that the dashboard has not yet received, so a transient
# outage (token rotation, redeploy, network) self-heals instead of silently
# losing entries. Tracks progress with a line-offset cursor and only advances
# it on a confirmed 2xx. Fire-and-forget: non-blocking, silent.

set -uo pipefail

export PBT_DASHBOARD_URL="${PBT_DASHBOARD_URL:-https://pbt-dashboard.vercel.app}"

# Paths first — resolve_secret() below writes to ERR_LOG, and `set -u` makes an
# unbound reference fatal.
LOG_FILE="$HOME/.pbt-log.jsonl"
STATE_FILE="$HOME/.pbt-sync-state"
ERR_LOG="$HOME/.pbt-sync-errors.log"
LOCK_DIR="$HOME/.pbt-sync.lock"
MAX_PER_RUN=200

# Secrets: never baked in as literals. This repo is published and served over a
# public CDN, so any default here is disclosed the moment it is committed.
#
# THE FILE WINS OVER THE ENVIRONMENT, which is the opposite of the usual
# convention, and deliberately so. On 2026-09-16 a rotated bypass secret was
# written to ~/.pbt/vercel-bypass and sync kept failing with 401 anyway,
# because ~/.zprofile still exported the old dead value and the original
# `[ -z "$VAR" ] && read-the-file` logic meant the file was never consulted.
# The symptom — an edge 401 with no runtime log — looks nothing like its cause,
# and it costs an hour to find. ~/.pbt/* is the managed, rotatable store; a
# stale export is the known foot-gun. So the file takes precedence and the
# disagreement is reported rather than silently resolved.
resolve_secret() {
  # $1 = var name, $2 = file path
  local var="$1" file="$2" env_val file_val
  eval "env_val=\${$var:-}"
  file_val=""
  [ -r "$file" ] && file_val="$(tr -d '[:space:]' < "$file")"

  if [ -n "$file_val" ] && [ -n "$env_val" ] && [ "$file_val" != "$env_val" ]; then
    printf '%s %s: environment and %s disagree; using the file. Remove the stale export.\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$var" "$file" >> "$ERR_LOG"
    printf 'pbt-sync.sh: %s in the environment differs from %s — using the file. Remove the stale export (check ~/.zprofile, ~/.zshrc).\n' \
      "$var" "$file" >&2
  fi

  if [ -n "$file_val" ]; then
    eval "export $var=\"\$file_val\""
  else
    eval "export $var=\"\$env_val\""
  fi
}

resolve_secret PBT_API_TOKEN     "$HOME/.pbt/api-token"
resolve_secret PBT_VERCEL_BYPASS "$HOME/.pbt/vercel-bypass"

[ -f "$LOG_FILE" ] || exit 0

# Self-healing lint before sync. Catches any entry that reached the log without
# going through pbt-log.sh (four did between 2026-08-19 and 2026-09-15, each
# surviving days until the Monday audit). Normalizing here also stops malformed
# entries being POSTed and rejected — see the HTTP 400 skips for lines 837,
# 1089, 1122 and 1144 in ~/.pbt-sync-errors.log.
#
# pbt-lint.py adjusts STATE_FILE itself if it has to remove a line, so it must
# run BEFORE the cursor is read below. It always exits 0.
# Findings go to ~/PBT/ rather than $HOME because that is the folder the
# Monday audit has mounted — otherwise the audit cannot see what the lint
# caught during the week.
if [ -f "$HOME/.pbt/bin/pbt-lint.py" ]; then
  PBT_LOG_FILE="$LOG_FILE" PBT_SYNC_STATE="$STATE_FILE" \
  PBT_LINT_FINDINGS="$HOME/PBT/.pbt-lint-findings.jsonl" \
    python3 -I "$HOME/.pbt/bin/pbt-lint.py" 2>/dev/null || true
fi

# Single-flight lock with stale reclaim (a killed worker must not wedge sync).
if [ -d "$LOCK_DIR" ] && find "$LOCK_DIR" -maxdepth 0 -mmin +2 >/dev/null 2>&1; then
  rmdir "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0

# Detach the worker so the hook returns immediately.
(
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

  total=$(awk 'END{print NR}' "$LOG_FILE" 2>/dev/null)
  case "$total" in ''|*[!0-9]*) exit 0 ;; esac
  [ "$total" -eq 0 ] && exit 0

  synced=$(cat "$STATE_FILE" 2>/dev/null)
  case "$synced" in ''|*[!0-9]*) synced="" ;; esac
  # First run: treat all but the newest as already synced (history is handled
  # by backfill, not this hook).
  [ -z "$synced" ] && synced=$((total - 1))
  [ "$synced" -lt 0 ] && synced=0
  # Log shrank or was rewritten; clamp to avoid re-posting.
  [ "$synced" -gt "$total" ] && synced=$total

  if [ "$synced" -ge "$total" ]; then
    printf '%s' "$synced" > "$STATE_FILE"
    exit 0
  fi

  posted=0
  i=$((synced + 1))
  while [ "$i" -le "$total" ] && [ "$posted" -lt "$MAX_PER_RUN" ]; do
    line=$(sed -n "${i}p" "$LOG_FILE")

    if [ -z "$line" ]; then
      printf '%s' "$i" > "$STATE_FILE"
      i=$((i + 1))
      continue
    fi

    payload=$(printf '%s' "$line" | python3 -c "
import sys, json, os
try:
    e = json.loads(sys.stdin.read())
except Exception:
    sys.exit(3)
if not e.get('user'):
    e['user'] = os.environ.get('USER', 'unknown')
sys.stdout.write(json.dumps(e))
" 2>/dev/null)

    if [ -z "$payload" ]; then
      printf '%s skip line %s: invalid JSON\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" >> "$ERR_LOG"
      printf '%s' "$i" > "$STATE_FILE"
      i=$((i + 1))
      continue
    fi

    CURL_ARGS=(-s -o /dev/null -w '%{http_code}' -X POST "${PBT_DASHBOARD_URL}/api/log"
      -H "Content-Type: application/json"
      --connect-timeout 5 --max-time 10)
    [ -n "$PBT_API_TOKEN" ] && CURL_ARGS+=(-H "Authorization: Bearer $PBT_API_TOKEN")
    [ -n "$PBT_VERCEL_BYPASS" ] && CURL_ARGS+=(-H "x-vercel-protection-bypass: $PBT_VERCEL_BYPASS")

    code=$(printf '%s' "$payload" | curl "${CURL_ARGS[@]}" -d @-)
    curl_rc=$?

    if [ "$curl_rc" -ne 0 ]; then
      printf '%s retry later at line %s: curl exit %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" "$curl_rc" >> "$ERR_LOG"
      break
    fi

    case "$code" in
      200|201)
        printf '%s' "$i" > "$STATE_FILE"
        posted=$((posted + 1))
        i=$((i + 1))
        ;;
      400)
        # Malformed entry per server validation — skip permanently so one bad
        # line never blocks the queue.
        printf '%s skip line %s: HTTP 400 (invalid entry)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" >> "$ERR_LOG"
        printf '%s' "$i" > "$STATE_FILE"
        i=$((i + 1))
        ;;
      *)
        # Auth/protection/rate-limit/server error — environmental and
        # transient. Stop and retry on the next stop event.
        printf '%s retry later at line %s: HTTP %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" "$code" >> "$ERR_LOG"
        break
        ;;
    esac
  done
) >/dev/null 2>&1 &

exit 0

PBT_SYNC_EOF
  chmod +x "$sync_file"
  green "✓ Shared sync → ${sync_file}"
  installed+=(".pbt/bin/pbt-sync.sh")
}

# ──────────────────────────────────────────
# 5. Stop hook: ~/.cursor/hooks/pbt-stop.sh (thin wrapper)
# ──────────────────────────────────────────
install_stop_hook() {
  local dir="${CURSOR_DIR}/hooks"
  local file="${dir}/pbt-stop.sh"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'HOOK_EOF'
#!/bin/bash
# Cursor stop hook — thin wrapper to shared PBT sync.
exec "$HOME/.pbt/bin/pbt-sync.sh"
HOOK_EOF

  chmod +x "$file"
  green "✓ Stop hook wrapper installed → ${file}"
  installed+=("hooks/pbt-stop.sh")
}

# ──────────────────────────────────────────────────
# 6. Log helper: ~/.cursor/hooks/pbt-log.sh (thin wrapper)
# ──────────────────────────────────────────────────
install_log_helper() {
  local dir="${CURSOR_DIR}/hooks"
  local file="${dir}/pbt-log.sh"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'LOGHELPER_EOF'
#!/bin/bash
# Cursor log helper — thin wrapper to shared gated PBT logger.
# Prefer ~/.pbt/bin/pbt-log.sh; this path remains for allowlist continuity.
exec "$HOME/.pbt/bin/pbt-log.sh"
LOGHELPER_EOF

  chmod +x "$file"
  green "✓ Log helper wrapper installed → ${file}"
  yellow "  Note: re-run this installer on any machine that still has the old unguarded pbt-log.sh"
  installed+=("hooks/pbt-log.sh")
}


# ──────────────────────────────────────────────────────────────────────
# 7. Backup script: ~/.cursor/skills/plan-build-test/scripts/backup-log.sh
# ──────────────────────────────────────────────────────────────────────
install_backup_script() {
  local dir="${CURSOR_DIR}/skills/plan-build-test/scripts"
  local file="${dir}/backup-log.sh"
  mkdir -p "$dir"
  backup_if_exists "$file"

  cat > "$file" <<'BACKUP_EOF'
#!/bin/bash
#
# PBT Log Backup
#
# Creates a timestamped snapshot of ~/.pbt-log.jsonl before any audit or
# destructive operation. Keeps the last 30 backups and prunes older ones.
#
# Usage:
#   bash backup-log.sh
#   bash backup-log.sh /path/to/other.jsonl   # backup a specific log file
#
# Called automatically as step 1 of any Cowork audit task. Can also be run
# manually at any time — it is idempotent and non-destructive.

set -euo pipefail

LOG_FILE="${1:-$HOME/.pbt-log.jsonl}"
BACKUP_DIR="$HOME/.pbt-log-backups"
MAX_BACKUPS=30

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

if [ ! -f "$LOG_FILE" ]; then
  red "Log file not found: $LOG_FILE"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/pbt-log_${TIMESTAMP}.jsonl"

cp "$LOG_FILE" "$BACKUP_FILE"

LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
FILE_SIZE=$(du -sh "$LOG_FILE" | cut -f1)

green "✓ Backup created → $BACKUP_FILE"
dim  "  Source: $LOG_FILE ($LINE_COUNT lines, $FILE_SIZE)"

# Prune oldest backups beyond MAX_BACKUPS
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/pbt-log_*.jsonl 2>/dev/null | wc -l | tr -d ' ')

if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
  EXCESS=$(( BACKUP_COUNT - MAX_BACKUPS ))
  ls -1t "$BACKUP_DIR"/pbt-log_*.jsonl | tail -"$EXCESS" | xargs rm
  dim "  pruned $EXCESS oldest backup(s) — kept $MAX_BACKUPS most recent"
  BACKUP_COUNT=$MAX_BACKUPS
fi

green "✓ Done — $BACKUP_COUNT backup(s) in $BACKUP_DIR"
BACKUP_EOF

  chmod +x "$file"
  green "✓ Backup script installed → ${file}"
  installed+=("skills/plan-build-test/scripts/backup-log.sh")
}

# ───────────────────────────────────────────────────────────────
# 8. CLI config: ~/.cursor/cli-config.json (MERGE permissions)
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
    'Shell(**pbt-log.sh*)',
    'Shell(**/.pbt/bin/pbt-log.sh*)',
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

# ───────────────────────────────────────────────────────────────────
# 9. Auto-backfill: post any local entries the dashboard doesn't have
# ───────────────────────────────────────────────────────────────────
backfill_missing() {
  local log_file="$HOME/.pbt-log.jsonl"
  local dashboard_url="https://pbt-dashboard.vercel.app"
  # Resolved, never baked in — install.sh is served over a public CDN.
  local bypass="${PBT_VERCEL_BYPASS:-}"
  if [ -z "$bypass" ] && [ -r "$HOME/.pbt/vercel-bypass" ]; then
    bypass="$(tr -d '[:space:]' < "$HOME/.pbt/vercel-bypass")"
  fi
  # /api/log fails closed on PBT_API_TOKEN, so the reconcile needs it too.
  # Without it every POST here returns 401, which was then mis-reported as
  # a validation failure — 94 entries on 2026-09-17.
  local api_token="${PBT_API_TOKEN:-}"
  if [ -z "$api_token" ] && [ -r "$HOME/.pbt/api-token" ]; then
    api_token="$(tr -d '[:space:]' < "$HOME/.pbt/api-token")"
  fi
  if [ -z "$api_token" ]; then
    yellow "⚠ no PBT_API_TOKEN (env or ~/.pbt/api-token) — the dashboard will"
    yellow "  reject every backfill POST with 401. Set it, then re-run."
  fi

  if [ ! -f "$log_file" ]; then
    dim "  (no local log at $log_file — skipping backfill)"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    yellow "⚠ python3 not found — skipping backfill"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    yellow "⚠ curl not found — skipping backfill"
    return 0
  fi

  echo ""
  echo "────────────────────────────────────────────────"
  echo ""
  echo "Reconciling local log with dashboard…"

  # Fetch the dashboard's known (ts, user) pairs. Soft-fail on any error.
  local remote_set
  remote_set=$(curl -fsS --max-time 20 \
    -H "x-vercel-protection-bypass: $bypass" \
    "${dashboard_url}/api/entries?limit=5000" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
seen = set()
for e in data.get('entries', []):
    ts = e.get('ts') or ''
    user = e.get('user') or ''
    if ts:
        seen.add(f'{ts}|{user}')
print('\n'.join(sorted(seen)))
") || {
    yellow "⚠ couldn't reach dashboard for backfill — your hook is installed; run again later if needed"
    return 0
  }

  # Walk the local log and POST any entries whose (ts, user) is not on the dashboard.
  local result
  result=$(REMOTE_SET="$remote_set" \
           DASHBOARD_URL="$dashboard_url" \
           BYPASS="$bypass" \
           API_TOKEN="$api_token" \
           LOG_FILE="$log_file" \
    python3 <<'PY'
import json, os, subprocess, sys

remote = set(line for line in os.environ.get('REMOTE_SET','').splitlines() if line)
dashboard_url = os.environ['DASHBOARD_URL']
bypass = os.environ['BYPASS']
api_token = os.environ.get('API_TOKEN', '')
log_file = os.environ['LOG_FILE']

posted = failed = skipped = 0
total = 0
codes = {}

with open(log_file, 'r', encoding='utf-8', errors='replace') as f:
    for raw in f:
        line = raw.strip()
        if not line:
            continue
        total += 1
        try:
            entry = json.loads(line)
        except Exception:
            failed += 1
            continue

        ts = entry.get('ts') or ''
        user = entry.get('user') or os.environ.get('USER', 'unknown')
        if not entry.get('user'):
            entry['user'] = user
        key = f'{ts}|{user}'
        if key in remote:
            skipped += 1
            continue

        body = json.dumps(entry)
        try:
            cmd = ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
                   '--connect-timeout', '5', '--max-time', '15',
                   '-X', 'POST', f'{dashboard_url}/api/log',
                   '-H', 'Content-Type: application/json',
                   '-H', f'x-vercel-protection-bypass: {bypass}']
            if api_token:
                cmd += ['-H', f'Authorization: Bearer {api_token}']
            cmd += ['-d', body]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
            code = r.stdout.strip()
        except Exception:
            code = '000'

        if code == '201':
            posted += 1
            # Add to remote set so a duplicate ts/user later in the file is skipped.
            remote.add(key)
        else:
            failed += 1
            codes[code] = codes.get(code, 0) + 1

# Report the actual HTTP codes rather than guessing at a cause.
detail = ','.join('%s:%d' % (c, k) for c, k in sorted(codes.items()) if c != '201')
print(f'{posted}|{failed}|{skipped}|{total}|{detail}')
PY
)

  local bf_posted bf_failed bf_skipped bf_total bf_codes
  IFS='|' read -r bf_posted bf_failed bf_skipped bf_total bf_codes <<< "$result"
  bf_posted=${bf_posted:-0}
  bf_failed=${bf_failed:-0}
  bf_skipped=${bf_skipped:-0}
  bf_total=${bf_total:-0}

  if [ "$bf_posted" -gt 0 ]; then
    green "✓ Backfill: posted $bf_posted new entries to the dashboard"
  fi
  if [ "$bf_skipped" -gt 0 ] && [ "$bf_posted" -eq 0 ] && [ "$bf_failed" -eq 0 ]; then
    green "✓ Backfill: dashboard already has all $bf_skipped local entries — nothing to do"
  fi
  dim "  scanned $bf_total local entries: $bf_posted posted, $bf_skipped already present, $bf_failed failed"
  if [ "$bf_failed" -gt 0 ]; then
    yellow "⚠ $bf_failed entries could not be posted — HTTP ${bf_codes:-unknown}"
    case "${bf_codes:-}" in
      *401*) yellow "  401 = auth, not data. Check PBT_API_TOKEN matches the value on the Vercel project and that ~/.pbt/vercel-bypass is current." ;;
      *503*) yellow "  503 = PBT_API_TOKEN is not configured on the Vercel project." ;;
      *400*) yellow "  400 = the dashboard judged the entry unrecoverable; run pbt-repair.py to see which." ;;
    esac
  fi
}


# ──────────────────────────────────────────
# 10. Claude Code: always-on rule
# ──────────────────────────────────────────
install_claude_rule() {
  local dir="${CLAUDE_DIR}/rules"
  local file="${dir}/plan-build-test.md"
  mkdir -p "$dir"
  backup_if_exists "$file"
  cat > "$file" <<'CLAUDE_RULE_EOF'
# Plan-Build-Test Workflow

For **every coding/implementation turn** in Claude Code — new features, bug fixes, refactoring, edits, style changes — follow the full workflow in:

`~/.claude/skills/plan-build-test/SKILL.md`

(or invoke `/plan-build-test`).

## Skip when all are true

1. The user only asks to explain, review, or plan — no file mutations planned.
2. You will not run Write/Edit/NotebookEdit or mutating Bash in this turn.
3. The user is not asking to fix a broken build/test/UI from a prior edit.

If any file-mutating tool runs after a skip, emit a triage label before further edits and complete the log step before declaring done.

## Non-negotiables

1. **First output line** of every coding response MUST be the triage label — before any tool call:
   - `P.B.T. Trivial: make the change, no plan needed`
   - `P.B.T. Small Scope: abbreviated plan, then build and test`
   - `P.B.T. Complex: full plan-build-test workflow`
   - `P.B.T. Investigative: spike first, then plan-build-test`

2. **Last action** is logging via `~/.pbt/bin/pbt-log.sh` into `~/.pbt-log.jsonl`. Use exact field names `ts`, `triage`, `task` — never aliases (`timestamp`, `tier`, `goal`).

3. **Log schema** lives at `~/.pbt/log-schema.md`.

CLAUDE_RULE_EOF
  green "✓ Claude rule installed → ${file}"
  installed+=(".claude/rules/plan-build-test.md")
}

# ──────────────────────────────────────────
# 11. Claude Code: skills-dir plugin
# ──────────────────────────────────────────
install_claude_plugin() {
  local root="${CLAUDE_DIR}/skills/plan-build-test"
  mkdir -p "${root}/.claude-plugin" "${root}/hooks" "${root}/scripts"

  backup_if_exists "${root}/SKILL.md"
  cat > "${root}/SKILL.md" <<'CLAUDE_SKILL_EOF'
---
name: plan-build-test
description: Use when the user asks for code changes, new features, bug fixes, refactoring, edits, style changes, or any implementation work. Also use when the user reports an error or broken behavior after a previous edit.
---

# Plan-Build-Test Workflow

**This workflow applies to coding/implementation turns in Claude Code.** Skip when the user only asks to explain, review, or plan with no file mutations planned, and is not asking to fix a broken build/test/UI from a prior edit. If any file-mutating tool runs after a skip, emit a triage label before further edits and complete Step 5 before declaring done. The always-on rule at `~/.claude/rules/plan-build-test.md` restates these non-negotiables.

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
> **⛔ Anti-pattern: reading code to reduce triage uncertainty.** A wrong tier is cheap — escalate mid-task with a one-line note. A pre-triage tool call is unrecoverable: you cannot un-read the code.
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

**Common pre-triage rationalizations — all are violations:**

| Excuse | Reality |
|--------|---------|
| "I need to find the file first to understand the task." | File location is irrelevant to triage. Classify from what the user asked, not what the code looks like. |
| "Let me just quickly check what's already there." | There is no such thing as a quick pre-check. Any tool call before the label is a violation. |
| "The request is vague — I need more context before I can classify." | Vague request → ask the user to clarify using `AskUserQuestion`. Do NOT read code to resolve vagueness. |
| "I'll output the label right after this one search." | No. Label first. One pre-triage tool call is the same violation as ten. |

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

> **⛔ If your Approach sentence uses hedging language about whether something will work, STOP.** Use `AskUserQuestion` to present the options to the user, or escalate to Investigative. A Small Scope plan must not contain speculation.

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
> 1. **Ask the user.** Use the `AskUserQuestion` tool to present the competing hypotheses as choices. State what you know, what you don't, and let the user pick which to try. Then spike that one.
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

**Common build-before-plan rationalizations — all are violations:**

| Excuse | Reality |
|--------|---------|
| "The user is blocked — I'll explain my approach as I go." | Urgency doesn't remove the requirement. A plan written under pressure is faster than code that needs a rewrite. |
| "I'll summarize what I did at the end — that's essentially a plan." | Post-build summaries describe what happened. Plans constrain what will happen. They are not equivalent. |
| "The approach is obvious — documenting it would be overhead." | If it's obvious, the plan takes 2 minutes. If it surprises you mid-build, the plan would have caught it. |
| "I'll just start and adjust as I go." | This is exactly what Complex tier exists to prevent. The plan is a pre-build checklist, not a post-build report. |

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
1. **Build gate (mandatory).** Run the project's compile/build command (`tsc --noEmit`, `npm run build`, or equivalent) on every edit — including Trivial fixes. If it fails, fix before continuing. This is not optional. A lint-only check does not replace a build pass; linters do not catch TDZ errors, unclosed JSX, or missing imports that a full compile does. A clean build is also necessary but not sufficient — type-only imports, dead branches, and string-literal references all evade compile-time checking. For bulk renames or symbol swaps, see the Task-shape recipes below.
2. **Runtime gate (mandatory for web projects).** After the build passes, confirm the app actually serves a page. Skip only for libraries, CLI tools, or projects with no running server.
   - If a dev server is running (check terminal output or `lsof -i :3000` / equivalent port), hit the main route with `curl -s -o /dev/null -w '%{http_code}' http://localhost:<port>` and confirm a 2xx response.
   - If the response is not 2xx, or the body contains error signatures (`Server Error`, `Cannot find module`, `Internal Server Error`, `502`, `503`, Cloudflare error tokens), the gate fails.
   - **Stale cache recovery:** If the error matches a module-not-found pattern (e.g., `Cannot find module './XXX.js'`), delete the build cache directory (`.next`, `dist`, `.cache`, or equivalent), restart the dev server, and re-check. This catches `.next` desync from running `npm run build` while the dev server is active.
   - If no dev server is running and the project is a web app, start it, wait for the ready signal, run the check, then stop it (or leave it running if the user's workflow expects it).
   - **Stylesheet sanity check:** After confirming a 2xx response, verify stylesheet links resolve — a page can return 200 OK with completely broken styles. Script: `~/.claude/skills/plan-build-test/scripts/step4-gates.md`. If any stylesheet returns non-200, the runtime gate fails.
   - **User load confirmation (dev server already running only).** If a dev server was already running when the runtime gate started (i.e., you did not start it), use `AskUserQuestion` to prompt the user:
     > *"The app is serving on localhost:\<port\>. Did it load correctly in your browser?"* — options: **Yes** / **No**
     - **Yes**: runtime gate passes, continue to item 3.
     - **No**: escalate the current task to **Investigative** tier. Note `[load-check escalation]` after the triage label. Set `escalated: true` and `escalated_from` to the current tier in the log. Proceed to Step 1.5 (Spike) to diagnose the loading issue before continuing.
   - **Failure = blocker.** Do not proceed to tests or visual verification until the runtime gate passes (including the stylesheet check and user confirmation above). A build that compiles but crashes at runtime is not a passing build.
3. **Run existing tests** that cover modified code. If any fail, fix them before continuing.
4. **Write new tests** for every new behavior introduced:
   - Primary success path
   - At least one error or edge case
   - Any boundary conditions identified in the plan's risks
   - Any recipes from "Task-shape recipes" below that match this change

   **Task-shape recipes** — mandatory test cases by task shape. When the change matches one of these shapes, the listed verification is required in addition to the generic cases above. Build success is necessary but not sufficient for these shapes.

   - **Pure function on key/identifier arrays** (sort, filter, dedupe, diff, reorder, `indexOf`-based lookup): include at least one test with duplicate keys. Functions whose signature is `(keys: K[]) => ...` have a collision failure mode by default — `indexOf` returns only the first match, `Set`-based dedupe drops repeats, stable-sort assumptions break, and so on. Generic happy / empty / null cases will not surface this.
   - **Bulk symbol rename / find-and-replace / framework swap**: after the edit, run `rg <old-symbol>` (or equivalent) across the source tree and confirm zero hits in non-generated files. The build gate does not catch this — type-only imports are tree-shaken silently, and dead branches, dynamic `require()` strings, and string-literal references all evade compile-time checking.

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

**Common log-skipping rationalizations — all are violations:**

| Excuse | Reality |
|--------|---------|
| "The task is done — the code change is made." | Done means the log is written. Code change + no log = task 90% complete. |
| "It was only a quick rename, nothing worth logging." | Every completed task logs, including Trivial. Especially Trivial — they're the ones most likely to skip it. |
| "We're wrapping up the session, I'll log next time." | There is no next time. The log is the last action of this task, before anything else. |
| "I summarized in my response — that's enough." | The response is for the user. The log entry is for the system. They serve different purposes. |

**⛔ MANDATORY: Re-read the schema file before writing the log.** Do not write the log from memory. Field names have exact spellings, and every one of the 27 fields belongs in the entry.

The helper validates the **full schema** and repairs what it can rather than rejecting: a missing field gets its default, `files_changed: ["a.tsx","b.tsx"]` becomes `2`, an alias like `files_touched` is mapped to the real field, and an off-schema key such as `outcome` or `result` is moved into `notes` as a `[pbt-salvage]` block. It prints on stderr whatever it corrected.

**Do not treat that as licence to be sloppy.** Normalization is a safety net for the log, not a substitute for a correct entry — a defaulted field records nothing, and a salvaged key means a real metric ended up as free text. If stderr shows corrections, the payload was wrong; fix it next time. Only four things are unrecoverable and quarantine the entry outright: unparseable JSON, no `ts`, no `task`, and a `triage` that isn't one of the four values.

**`language` is the one attribution field only you can supply.** Nothing else knows what you changed, so if you omit it the entry is permanently unattributable by language — as of 2026-09-17 that accounts for 238 entries, every single one of the log's unattributable records. Always set it to the primary language of the change (`ts`, `py`, `css`, `md`, `sh`, …).

`user` and `project` are now derived by the helper — `whoami`, and the basename of the git repo root — because they are knowable at write time and were being dropped on 15–18% of entries. **Still set them when you know them:** the helper only fills a gap, never overrides you, and it cannot derive `project` outside a git repo. When it has to step in it records `_derived_by_helper` on the entry, and the weekly audit reports that as emitter sloppiness rather than a clean payload.

**The triage label is response text, not data.** The `P.B.T. ` prefix belongs on the first line of your reply; the `triage` field takes the bare value (`"Complex"`, never `"P.B.T. Complex"`).

```bash
cat ~/.pbt/log-schema.md
```

Then:

1. Build the JSON payload using ONLY the field names in the schema
2. Pipe the JSON line to the log helper script:
   ```bash
   echo '{"ts":"...","user":"..."}' | ~/.pbt/bin/pbt-log.sh
   ```
   **⛔ Do NOT use `printf` or `echo` with `>>` to write directly to `~/.pbt-log.jsonl`.** Direct writes trigger an approval prompt in Cursor IDE on every task because the payload is unique each time. The helper script has a fixed name that can be allowlisted once.
3. If `$PBT_SLACK_WEBHOOK` is set, send to Slack per the reference file

If the pipe or curl command fails, note the failure to the user and move on — a logging failure should not block the user. But you must *attempt* it before declaring done.

**A nonzero exit from `pbt-log.sh` means the entry was quarantined, not logged.** The reason is on stderr. Tell the user, in one line, that the task is done but the log entry was rejected and why — do not report a clean "done". The entry is recoverable from `~/.pbt-log-quarantine.jsonl`.

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

CLAUDE_SKILL_EOF

  cat > "${root}/.claude-plugin/plugin.json" <<'CLAUDE_PLUGIN_JSON_EOF'
{
  "name": "plan-build-test",
  "version": "1.0.0",
  "description": "Plan-Build-Test workflow for Claude Code — triage, plan, build, test, and log to the shared PBT dashboard."
}
CLAUDE_PLUGIN_JSON_EOF

  cat > "${root}/hooks/hooks.json" <<'CLAUDE_HOOKS_EOF'
{
  "description": "PBT dashboard sync after each Claude Code turn",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash",
            "args": ["-lc", "$HOME/.pbt/bin/pbt-sync.sh"],
            "async": true
          }
        ]
      }
    ]
  }
}
CLAUDE_HOOKS_EOF

  cat > "${root}/scripts/log-schema.md" <<'CLAUDE_SCHEMA_EOF'
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

CLAUDE_SCHEMA_EOF

  cat > "${root}/scripts/step4-gates.md" <<'CLAUDE_GATES_EOF'
# Step 4 Gate Scripts

## Stylesheet sanity check

Run after confirming a 2xx response from the dev server. Verifies that every CSS file referenced in the page HTML actually resolves. A page can return 200 OK with completely broken styles — this catches the "CSS file 404" class of bugs that a status-code-only check misses.

```bash
curl -s http://localhost:<port> \
  | grep -oP '(?<=href=")[^"]*\.css[^"]*' \
  | while read href; do
      url=$(echo "$href" | grep -q '^http' && echo "$href" || echo "http://localhost:<port>$href")
      status=$(curl -s -o /dev/null -w '%{http_code}' "$url")
      [ "$status" != "200" ] && echo "FAIL: $href returned $status" && exit 1
    done
```

If any stylesheet returns non-200, the runtime gate fails.

CLAUDE_GATES_EOF

  green "✓ Claude skills-dir plugin → ${root}"
  installed+=(".claude/skills/plan-build-test/")
}

# ──────────────────────────────────────────
# 12. Claude Code: permissions.allow for pbt-log
# ──────────────────────────────────────────
install_claude_permissions() {
  local file="${CLAUDE_DIR}/settings.json"
  mkdir -p "$CLAUDE_DIR"
  backup_if_exists "$file"

  local result
  result=$(python3 -c "
import json, os
path = os.path.expanduser('~/.claude/settings.json')
allow = [
    'Bash(*pbt-log.sh)',
    'Bash(*pbt-log.sh *)',
]
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        data = {}
else:
    data = {}
perms = data.setdefault('permissions', {})
arr = perms.setdefault('allow', [])
existing = set(arr)
added = []
for p in allow:
    if p not in existing:
        arr.append(p)
        added.append(p)
if not added:
    print('SKIPPED')
else:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print('INSTALLED')
")

  if [ "$result" = "SKIPPED" ]; then
    green "✓ Claude settings.json — Bash(*pbt-log.sh) already allowed"
    skipped+=("claude settings permissions")
  else
    green "✓ Claude settings.json — Bash(*pbt-log.sh) permissions added"
    installed+=(".claude/settings.json")
  fi
}


# ──────────────────────────────────────────
# 13. Claude Design: prepare upload ZIP
# ──────────────────────────────────────────
install_design_zip() {
  local out_dir out_zip staging
  if [ -d "$HOME/Downloads" ] && [ -w "$HOME/Downloads" ]; then
    out_dir="$HOME/Downloads"
  else
    out_dir="${TMPDIR:-/tmp}"
    out_dir="${out_dir%/}"
  fi
  out_zip="${out_dir}/plan-build-test-design.zip"
  staging=$(mktemp -d "${TMPDIR:-/tmp}/pbt-design.XXXXXX")
  mkdir -p "${staging}/plan-build-test-design/scripts"

  cat > "${staging}/plan-build-test-design/SKILL.md" <<'DESIGN_SKILL_EOF'
---
name: plan-build-test-design
description: Plan-Build-Test for Claude Design — triage, plan, and log canvas/prototype/deck/wireframe work with exact ts/triage/task. Skip pure Q&A.
---

# Plan-Build-Test for Claude Design

Use this skill on **implementation** turns in Claude Design (canvas mutations: prototypes, decks, wireframes, mockups). Do **not** require the user to type `/` every prompt — auto-invoke when the request matches. `/plan-build-test-design` is troubleshooting only.

## Skip when all are true

1. User asks to explain, review, or plan only — no canvas implementation.
2. The turn will not create/edit canvas content.
3. User is not asking to fix a broken design from a prior turn.

If you mutate the canvas after skipping, emit a triage label before further changes and complete the log step.

## Step 1 — Triage (first output line)

```
P.B.T. Trivial: make the change, no plan needed
P.B.T. Small Scope: abbreviated plan, then build and test
P.B.T. Complex: full plan-build-test workflow
P.B.T. Investigative: spike first, then plan-build-test
```

- Trivial: tiny copy/color tweak, 1–2 obvious fixes.
- Small Scope: contained layout change; short Goal/Files/Approach plan first.
- Complex: new flow, many screens, or design-system trade-offs — full plan + risks.
- Investigative: unclear root cause or prior attempts failed — spike first.

Mark `[visual task]` when layout/visual appearance is the work.

## Step 2–4 — Plan / build / verify (adapted)

- Prefer canvas edits and comments over inventing unrelated surfaces.
- Visual check = review the canvas (and export preview if relevant). Do not skip when `[visual task]` or UI changed.
- No git/test-runner gates unless the user also handed work to Claude Code.

## Step 5 — Log (mandatory)

Re-read `scripts/log-schema.md` in this skill. Use **exact** field names only:

- `ts`, `triage`, `task` — required
- Never `timestamp`, `tier`, `goal`, `files_touched`

Then run:

```bash
python3 scripts/pbt_post.py <<'EOF'
{"ts":"...","user":"...","project":"claude-design","triage":"Trivial","task":"...","files_changed":0,"files_created":0,"tests_written":0,"tests_fixed":0,"all_tests_passed":true,"risks_identified":0,"risks_mitigated":0,"risks_out_of_scope":0,"risks_ask_user":0,"stopped_to_ask_user":false,"plan_deviations":0,"pre_existing_issues":[],"language":"design","visual_check":true,"visual_issues_found":0,"escalated":false,"escalated_from":null,"spiked":false,"spike_resolved":false,"mid_plan_spike":false,"duration_min":null,"notes":"claude-design"}
EOF
```

If `pbt_post.py` exits nonzero, tell the user logging failed and move on — do not POST garbage. The script validates before any network call.

## Troubleshooting

If the triage label is missing on a design implementation turn, invoke `/plan-build-test-design` once and continue.

DESIGN_SKILL_EOF

  cat > "${staging}/plan-build-test-design/scripts/pbt_post.py" <<'DESIGN_POST_EOF'
#!/usr/bin/env python3
"""PBT Design log poster — normalize, append locally when possible, then POST.

Uses the shared 27-field contract in pbt_schema.py rather than its own rules.
Before 2026-09-16 this file carried a hand-copied 3-field check (ts / triage /
task, extras allowed), one of four such copies; design entries therefore
reached the dashboard unvalidated for the other 24 fields.

Two behaviours changed on 2026-09-16:

1. **Local append.** This used to POST only, with the note "Does not write
   ~/.pbt-log.jsonl (Claude Design sandbox has no Mac home sync)". The
   consequence was that every Claude Design task was absent from the local log
   and therefore invisible to the weekly audit, which reads only that file. It
   now also appends through ~/.pbt/bin/pbt-log.sh whenever that helper is
   reachable, and silently skips the append when it is not — so design work
   shows up in the audit on a real Mac, and the sandbox behaves as before.

2. **No baked-in credential.** The Vercel protection-bypass token used to sit
   here as a literal default. This repo is published and served over a public
   CDN, so that value must be treated as disclosed. The token now comes from
   the environment or from ~/.pbt/vercel-bypass, and its absence is reported
   rather than silently papered over.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

# The schema module ships alongside this script (the design sandbox has no
# ~/.pbt), but prefer the installed copy when running on a real machine so a
# stale bundled copy cannot win.
_HERE = os.path.dirname(os.path.abspath(__file__))
for _candidate in (os.path.expanduser("~/.pbt/lib"), _HERE):
    if os.path.exists(os.path.join(_candidate, "pbt_schema.py")):
        sys.path.insert(0, _candidate)

try:
    import pbt_schema
    from pbt_schema import normalize
except Exception as _ex:  # pragma: no cover
    pbt_schema = None
    normalize = None
    _IMPORT_ERROR = _ex

DASHBOARD_URL = os.environ.get(
    "PBT_DASHBOARD_URL", "https://pbt-dashboard.vercel.app"
).rstrip("/")
LOG_HELPER = os.path.expanduser("~/.pbt/bin/pbt-log.sh")
BYPASS_FILE = os.path.expanduser("~/.pbt/vercel-bypass")
API_TOKEN_FILE = os.path.expanduser("~/.pbt/api-token")


def _secret(env_var: str, path: str) -> str:
    """Read a secret from the environment, else a local file. Never a literal."""
    value = os.environ.get(env_var, "").strip()
    if value:
        return value
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


API_TOKEN = _secret("PBT_API_TOKEN", API_TOKEN_FILE)


def resolve_bypass() -> str:
    """Vercel protection-bypass token, from the environment or a local file.

    Never defaulted to a literal: this file is published through a public CDN.
    """
    return _secret("PBT_VERCEL_BYPASS", BYPASS_FILE)


def append_locally(entry: dict) -> str:
    """Append via the gated helper. Returns a short status for the caller.

    Best-effort by design: the design sandbox has no Mac home, so a missing
    helper is normal there and must not fail the task.
    """
    if not os.path.exists(LOG_HELPER):
        return "skipped (no ~/.pbt/bin/pbt-log.sh — not a synced machine)"
    try:
        proc = subprocess.run(
            ["bash", LOG_HELPER],
            input=json.dumps(entry).encode("utf-8"),
            capture_output=True,
            timeout=15,
        )
    except Exception as ex:
        return "failed (%s)" % ex
    if proc.returncode == 0:
        return "appended to ~/.pbt-log.jsonl"
    detail = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
    return "quarantined by helper (%s)" % (detail or "no reason given")


def post_curl(body: bytes, bypass: str) -> int:
    cmd = [
        "curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
        "-X", "POST", f"{DASHBOARD_URL}/api/log",
        "-H", "Content-Type: application/json",
        "--connect-timeout", "5", "--max-time", "15",
        "-d", "@-",
    ]
    if bypass:
        cmd.extend(["-H", f"x-vercel-protection-bypass: {bypass}"])
    if API_TOKEN:
        cmd.extend(["-H", f"Authorization: Bearer {API_TOKEN}"])
    proc = subprocess.run(cmd, input=body, capture_output=True, timeout=20)
    if proc.returncode != 0:
        err = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
        print(f"pbt_post.py: curl failed: {err or proc.returncode}", file=sys.stderr)
        return 1
    code = (proc.stdout or b"").decode("utf-8", errors="replace").strip()
    if code not in ("200", "201"):
        print(f"pbt_post.py: HTTP {code}", file=sys.stderr)
        return 1
    print(f"pbt_post.py: ok HTTP {code}")
    return 0


def post_urllib(body: bytes, bypass: str) -> int:
    headers = {"Content-Type": "application/json"}
    if bypass:
        headers["x-vercel-protection-bypass"] = bypass
    req = urllib.request.Request(
        f"{DASHBOARD_URL}/api/log", data=body, method="POST", headers=headers
    )
    if API_TOKEN:
        req.add_header("Authorization", f"Bearer {API_TOKEN}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            code = resp.getcode()
            resp.read()
    except urllib.error.HTTPError as e:
        print(f"pbt_post.py: HTTP {e.code}", file=sys.stderr)
        try:
            print(e.read().decode("utf-8", errors="replace"), file=sys.stderr)
        except Exception:
            pass
        return 1
    except Exception as ex:
        print(f"pbt_post.py: request failed: {ex}", file=sys.stderr)
        return 1
    if code not in (200, 201):
        print(f"pbt_post.py: unexpected HTTP {code}", file=sys.stderr)
        return 1
    print(f"pbt_post.py: ok HTTP {code}")
    return 0


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        print("pbt_post.py: empty stdin", file=sys.stderr)
        return 1

    if normalize is None:
        print("pbt_post.py: pbt_schema.py not importable (%s); refusing to post "
              "unvalidated" % _IMPORT_ERROR, file=sys.stderr)
        return 1

    try:
        entry, dupes = pbt_schema.loads(raw)
    except Exception as ex:
        print("pbt_post.py: parse_error: %s" % ex, file=sys.stderr)
        return 1

    clean, changes, fatal = normalize(entry, dupes)
    if fatal:
        print("pbt_post.py: rejected (%s)" % "; ".join(fatal), file=sys.stderr)
        print("Required: ts, task, and triage as one of "
              "Trivial / Small Scope / Complex / Investigative. "
              "The triage field takes the bare value — not the "
              "'P.B.T. ' response label.", file=sys.stderr)
        return 1

    if changes:
        fills = [c for c in changes if c.startswith("filled missing ")]
        fixes = [c for c in changes if not c.startswith("filled missing ")]
        parts = []
        if fixes:
            parts.append("corrected: " + "; ".join(fixes))
        if fills:
            names = [c.split()[2].split("=")[0] for c in fills]
            parts.append("defaulted %d absent field(s): %s"
                         % (len(fills), ", ".join(names)))
        print("pbt_post.py: " + " | ".join(parts), file=sys.stderr)

    if clean.get("user") in (None, "", "unknown"):
        env_user = os.environ.get("USER", "").strip()
        if env_user:
            clean["user"] = env_user

    # Local first: the audit reads ~/.pbt-log.jsonl, so this is what makes
    # design work visible in the weekly report at all.
    print("pbt_post.py: local append %s" % append_locally(clean), file=sys.stderr)

    bypass = resolve_bypass()
    if not bypass:
        print("pbt_post.py: no PBT_VERCEL_BYPASS in the environment and no %s — "
              "posting without the bypass header; expect HTTP 401 if the "
              "deployment is protected." % BYPASS_FILE, file=sys.stderr)
    if not API_TOKEN:
        print("pbt_post.py: no PBT_API_TOKEN in the environment and no %s — "
              "/api/log refuses unauthenticated writes, so expect HTTP 401. "
              "The local append above already succeeded, so the entry is not "
              "lost." % API_TOKEN_FILE, file=sys.stderr)

    body = json.dumps(clean).encode("utf-8")
    if shutil.which("curl"):
        return post_curl(body, bypass)
    return post_urllib(body, bypass)


if __name__ == "__main__":
    raise SystemExit(main())
DESIGN_POST_EOF

  cat > "${staging}/plan-build-test-design/scripts/log-schema.md" <<'DESIGN_SCHEMA_EOF'
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

DESIGN_SCHEMA_EOF

  chmod +x "${staging}/plan-build-test-design/scripts/pbt_post.py"
  rm -f "$out_zip"

  local zipped=0
  if command -v zip >/dev/null 2>&1; then
    if (cd "$staging" && zip -r "$out_zip" plan-build-test-design \
        -x '*.DS_Store' -x '*/__pycache__/*' -x '*.pyc' >/dev/null); then
      zipped=1
    fi
  fi
  if [ "$zipped" -eq 0 ] && command -v python3 >/dev/null 2>&1; then
    if (cd "$staging" && python3 -m zipfile -c "$out_zip" plan-build-test-design); then
      zipped=1
    fi
  fi

  rm -rf "$staging"

  if [ "$zipped" -eq 0 ] || [ ! -f "$out_zip" ]; then
    red "✗ Could not create Design ZIP (need zip or python3 -m zipfile -c)"
    yellow "  Cursor/Code installs (if any) were kept. Package manually from claude-design/."
    return 0
  fi

  green "✓ Design skill ZIP → ${out_zip}"
  installed+=("design:${out_zip}")

  if [ "$(uname -s)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
    open -R "$out_zip" 2>/dev/null || true
  fi

  echo ""
  yellow "Claude Design — finish in the UI (required):"
  echo "  1. Open Claude → Customize → Skills"
  echo "  2. Upload: ${out_zip}"
  echo "  3. Enable the plan-build-test-design skill"
  echo "  4. Optional custom instructions:"
  echo "     On Claude Design canvas work (prototypes, decks, wireframes), follow the"
  echo "     plan-build-test-design skill: triage first line, then log with"
  echo "     scripts/pbt_post.py using exact ts/triage/task fields."
  echo ""
}

# ──────────────────────────────
# Main
# ──────────────────────────────
main() {
  prompt_hosts_if_needed

  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║   Plan-Build-Test (PBT) Installer            ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  local mode_bits=()
  [ "$INSTALL_CURSOR" -eq 1 ] && mode_bits+=("Cursor")
  [ "$INSTALL_CLAUDE" -eq 1 ] && mode_bits+=("Claude Code")
  [ "$INSTALL_DESIGN" -eq 1 ] && mode_bits+=("Claude Design (ZIP)")
  if [ ${#mode_bits[@]} -eq 0 ]; then
    INSTALL_CURSOR=1
    mode_bits=("Cursor")
  fi
  local mode_str=""
  local _i
  for _i in "${!mode_bits[@]}"; do
    if [ -n "$mode_str" ]; then
      mode_str="${mode_str} + "
    fi
    mode_str="${mode_str}${mode_bits[$_i]}"
  done
  dim "Mode: ${mode_str}"
  echo ""

  if [ "$INSTALL_CURSOR" -eq 1 ] || [ "$INSTALL_CLAUDE" -eq 1 ]; then
    install_shared_pbt
  fi

  if [ "$INSTALL_CURSOR" -eq 1 ]; then
    install_rule
    install_skill
    install_log_schema
    install_step4_gates
    install_backup_script
    install_hooks_json
    install_stop_hook
    install_log_helper
    install_cli_config
  fi

  if [ "$INSTALL_CLAUDE" -eq 1 ]; then
    install_claude_rule
    install_claude_plugin
    install_claude_permissions
  fi

  if [ "$INSTALL_CURSOR" -eq 1 ] || [ "$INSTALL_CLAUDE" -eq 1 ]; then
    backfill_missing
  fi

  # Design last so zip failure does not undo Cursor/Code.
  if [ "$INSTALL_DESIGN" -eq 1 ]; then
    install_design_zip
  fi

  echo ""
  echo "────────────────────────────────────────────────"
  echo ""
  green "Installed ${#installed[@]} artifact(s):"
  for f in "${installed[@]}"; do
    case "$f" in
      .pbt/*) echo "  ~/${f}" ;;
      .claude/*) echo "  ~/${f}" ;;
      design:*) echo "  ${f#design:} (upload to Customize > Skills)" ;;
      *) echo "  ~/.cursor/${f}" ;;
    esac
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
  if [ "$INSTALL_CURSOR" -eq 1 ]; then
    echo "  • Restart Cursor (Cmd+Shift+P → Reload Window)"
    echo "  • Agent mode prompts will trigger P.B.T. → ~/.pbt-log.jsonl → dashboard"
  fi
  if [ "$INSTALL_CLAUDE" -eq 1 ]; then
    echo "  • Restart Claude Code; confirm Stop → pbt-sync.sh via /hooks"
    echo "  • Coding turns log via ~/.pbt/bin/pbt-log.sh (exact ts/triage/task)"
  fi
  if [ "$INSTALL_DESIGN" -eq 1 ]; then
    echo "  • Upload the Design ZIP in Customize > Skills and enable it"
  fi
  echo ""
  yellow "Note: existing installs must re-run this installer to pick up the gated ~/.pbt/bin/pbt-log.sh + wrappers."
  echo ""
}

main "$@"
