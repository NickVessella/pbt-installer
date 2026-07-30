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
