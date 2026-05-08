# Plan-Build-Test (PBT) Installer

PBT is a **Cursor skill** (NOT a Claude plugin) that triages every coding request, gates complex work behind a plan-build-test workflow, and logs every task to a centralized dashboard for retrospective analysis.

## Install

One-line install. Idempotent — safe to re-run.

```bash
curl -fsSL https://raw.githubusercontent.com/NickVessella/pbt-installer/main/install.sh | bash
```

This deploys hooks, the skill, and a CLI permission bump into `~/.cursor/`. After install, every Agent-mode prompt in Cursor will produce a structured `P.B.T.` log entry POSTed to the dashboard.

## Repo layout

| Path | Contents |
|---|---|
| `install.sh` | Self-contained installer. Embeds every artifact via heredocs (`SKILL.md`, hooks, log helper, backup script, CLI config). |
| `dashboard/` | Vercel-hosted dashboard (`api/`, `public/`, `scripts/backfill.sh`). Live at <https://pbt-dashboard.vercel.app>. |
| `scripts/` | Helper utilities — `backup-log.sh`, `repair-log.sh`, `log-schema.md`, `cowork-audit-prompt.md`. |
| `scripts/orphans/` | Scripts that live at `~/.cursor/skills/plan-build-test/scripts/` but are NOT yet embedded in `install.sh` — kept here for version control: `pbt-audit.py`, `weekly_analysis.py`, `SETUP.md`. |

## Dashboard

See [`dashboard/README.md`](./dashboard/README.md) for deploy + env setup.

<!-- last verified auto-deploy: 2026-05-08 -->
