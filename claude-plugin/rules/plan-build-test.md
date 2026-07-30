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
