# Host overlays (edit-time)

Canonical workflow: [`../SKILL.md`](../SKILL.md).

| Host | Install target | Differences from canonical |
|---|---|---|
| Cursor | `~/.cursor/skills/plan-build-test/SKILL.md` | Agent/Plan/Ask mode gate via `plan-build-test.mdc`; log via `~/.pbt/bin/pbt-log.sh` |
| Claude Code | `~/.claude/skills/plan-build-test/SKILL.md` | No Cursor modes — use skip signals; same `~/.pbt` paths; AskUserQuestion instead of AskQuestion |
| Claude Design | `claude-design/plan-build-test-design/` | Canvas triage; log via `scripts/pbt_post.py` (no local jsonl); description ≤200 chars |

After editing `skill/SKILL.md`, re-sync the matching heredocs in `install.sh` (and Design ZIP sources) before commit. `install.sh` does **not** read `skill/` at `curl|bash` runtime.
