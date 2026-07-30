# Plan-Build-Test (PBT) Installer

PBT triages coding work, gates complex changes behind plan-build-test, and logs every task to one dashboard schema across **Cursor**, **Claude Code**, and **Claude Design**.

Live dashboard: <https://pbt-dashboard.vercel.app>

## Install (one command)

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/NickVessella/pbt-installer@main/install.sh | bash
# or from a clone:
bash install.sh
```

If `/dev/tty` is available (normal Terminal), you get a menu — prompts read from `/dev/tty` so they work under `curl | bash`:

```
Install PBT for which host(s)?
  1) Cursor
  2) Claude Code only
  3) Claude Design (ZIP prep — upload still required)
  4) All (Cursor + Code + Design)
  5) Cursor + Claude Code
Choose [1]:
```

Default is **1) Cursor**. Claude Design still needs one Upload click in Customize → Skills after the installer writes the ZIP (usually `~/Downloads/plan-build-test-design.zip`).

### Non-interactive flags

Exclusive flags select hosts (**multiple `*-only` combine**). `--with-claude` / `--with-design` **add** Code/Design. Default dual: `--with-claude`. Triple: `--all`.

```bash
curl … | bash -s -- --with-claude              # Cursor + Code
curl … | bash -s -- --all                      # Cursor + Code + Design ZIP
curl … | bash -s -- --design-only              # Design ZIP only
curl … | bash -s -- --claude-only --design-only  # Code + Design
bash install.sh -y                             # skip menu → Cursor
```

| Flag | Effect |
|---|---|
| `--cursor-only` | Cursor + `~/.pbt` |
| `--claude-only` | Claude Code + `~/.pbt` |
| `--design-only` | Prepare Design ZIP (no `~/.pbt`) |
| `--all` | Cursor + Code + Design ZIP |
| `--with-claude` | Add Code (keeps Cursor unless a `*-only` cleared it) |
| `--with-design` | Add Design ZIP prep |
| `-y` / `--yes` | Skip menu |

### What each host gets

- **Cursor:** rule, skill, thin hook wrappers → gated `~/.pbt/bin/pbt-log.sh` + `pbt-sync.sh`
- **Claude Code:** `~/.claude/rules/plan-build-test.md`, skills-dir plugin, async Stop → `$HOME/.pbt/bin/pbt-sync.sh`, `Bash(*pbt-log.sh)` permissions
- **Claude Design:** ZIP with `pbt_post.py` (same validation + default Vercel bypass). Upload in Customize → Skills and enable. Optional custom instructions are printed by the installer.

## Reporting pipeline

| Host | Path | Invalid behavior |
|---|---|---|
| Cursor / Claude Code | `~/.pbt/bin/pbt-log.sh` (Cursor also wraps `~/.cursor/hooks/pbt-log.sh`) | Quarantine + nonzero exit |
| Claude Design | `pbt_post.py` in the skill ZIP | No HTTP POST; stderr error |

Required: exact `ts`, `triage` ∈ `{Trivial, Small Scope, Complex, Investigative}`, `task`. No alias rename.

Re-run the installer on machines that still have an old unguarded `pbt-log.sh`.

## Repo layout

| Path | Contents |
|---|---|
| `install.sh` | Self-contained installer (heredocs). What `curl\|bash` ships. |
| `shared/` | Edit-time gated log/sync + schema → `~/.pbt/` |
| `skill/` | Cursor skill edit-time source |
| `claude-plugin/` | Claude Code plugin + rule source |
| `claude-design/` | Design skill source (sync into `install.sh` heredocs after edits) |
| `scripts/package-design-skill.sh` | Local ZIP packager for Design |
| `scripts/smoke-pbt-hosts.sh` | Alias quarantine + valid log (+ optional live Design POST) |
| `dashboard/` | Vercel dashboard |

**Dev sync:** After editing `skill/`, `claude-plugin/`, or `claude-design/`, re-sync the matching heredocs in `install.sh` before commit.

## Smoke

```bash
bash install.sh --with-claude
bash install.sh --design-only
bash scripts/smoke-pbt-hosts.sh
```

## Dashboard

See [`dashboard/README.md`](./dashboard/README.md) for deploy + env setup.

<!-- last verified auto-deploy: 2026-05-08 -->
