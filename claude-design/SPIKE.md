# Claude Design PBT — Phase 2 spike notes

Phase 1 (Cursor + Claude Code) ships independently of this spike.

## Checks

| # | Check | Expected | Result |
|---|---|---|---|
| 1 | Auto-load skill in Design without typing `/` | Skill applies on description match for canvas work | **Pending live Design session** — use slash fallback if auto-invoke fails; Phase 1 already shipped |
| 2 | Valid `pbt_post.py` POST (bypass header) | HTTP 201 + dashboard row | **Passed** via `PBT_SMOKE_LIVE=1 bash scripts/smoke-pbt-hosts.sh` |
| 3 | Alias / missing `task` via `pbt_post.py` | No HTTP POST; stderr reject | **Passed** (rejected before network) |
| 4 | Custom instructions one-liner | Optional nudge for Design/canvas turns | Snippet below |

## Optional Claude.ai custom instructions

```
On Claude Design canvas work (prototypes, decks, wireframes), follow the plan-build-test-design skill: triage first line, then log with scripts/pbt_post.py using exact ts/triage/task fields.
```

## Slash fallback (if auto-invoke fails)

Troubleshooting only: `/plan-build-test-design` once per stuck turn. Do not require `/` on every prompt when auto-invoke works.

## Install (Design)

1. Run `bash scripts/package-design-skill.sh`
2. Upload `dist/plan-build-test-design.zip` via Customize > Skills
3. Enable the skill
4. Optional: paste the custom-instructions snippet above
