I want you to build me a scheduled PBT log audit agent. Follow these steps exactly every time it runs.

**Path note:** This task assumes you have access to a folder mounted at `/mnt/PBT/` containing `.pbt-log.jsonl`. That folder corresponds to `~/PBT/` on the user's Mac (NOT `~/Documents/PBT/` — that path is TCC-protected and cannot be written to reliably by background jobs). All paths in this prompt use `/mnt/PBT/` — do NOT translate them to `~/` (which would resolve to the VM's home, not the user's Mac).

**Tooling note:** Do NOT invoke any `backup-log.sh` or other helper scripts that may exist in the user's repo — those are designed to run on the user's Mac, not in this environment, and they hardcode `$HOME` paths that won't resolve correctly here. Use ONLY the inline bash commands in this prompt.

---

## Step 1 — Local backup (mandatory, stop if this fails)

Run these inline backup commands exactly — do not substitute a script for them:
```bash
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
mkdir -p /mnt/PBT/.pbt-log-backups
cp /mnt/PBT/.pbt-log.jsonl /mnt/PBT/.pbt-log-backups/pbt-log_${TIMESTAMP}.jsonl
ls -1t /mnt/PBT/.pbt-log-backups/pbt-log_*.jsonl | tail -n +31 | xargs rm -f 2>/dev/null || true
echo "Backup created: /mnt/PBT/.pbt-log-backups/pbt-log_${TIMESTAMP}.jsonl"
```

If `/mnt/PBT/.pbt-log.jsonl` does not exist or the `cp` command fails, **stop immediately and notify me**. Do not proceed to any other step. When reporting the failure, include:
- The exact path you tried to read
- Whether `/mnt/PBT/` itself is mounted (`ls /mnt/PBT/`)
- The stat of the source file if it exists

---

## Step 2 — Google Drive offsite backup

Upload `/mnt/PBT/.pbt-log.jsonl` to Google Drive at the path:
`PBT Logs/pbt-log-latest.jsonl`

Also upload a dated copy at:
`PBT Logs/history/pbt-log_YYYY-MM-DD.jsonl`

If the Drive upload fails or no Google Drive connector is available, note it in the report but continue — the local backup from Step 1 is sufficient to proceed safely. Do not stop the audit over a Drive failure.

---

## Step 3 — Data quality audit (read-only from here, do NOT modify /mnt/PBT/.pbt-log.jsonl)

Read `/mnt/PBT/.pbt-log.jsonl`. For every line, check:

**Parse errors**
- Lines that are not valid JSON (malformed, multi-line records, truncated)

**Schema violations** — required fields using this exact schema:
```
ts, user, project, triage, task, files_changed, files_created,
tests_written, tests_fixed, all_tests_passed, risks_identified,
risks_mitigated, risks_out_of_scope, risks_ask_user,
stopped_to_ask_user, plan_deviations, pre_existing_issues,
language, visual_check, visual_issues_found, escalated,
escalated_from, spiked, spike_resolved, mid_plan_spike,
duration_min, notes
```

**Alias drift** — flag any entry using old/wrong field names:
- `timestamp` instead of `ts`
- `tier` instead of `triage`
- `files_touched` instead of `files_changed`
- `goal` instead of `task`
- Any field not in the schema above

**Wrong field types** — flag entries where:
- `files_changed`, `files_created`, `tests_written`, etc. are not integers (e.g. stored as a list)
- Boolean fields (`all_tests_passed`, `escalated`, etc.) are stored as strings

**Invalid enum values** — `triage` must be exactly one of: `Trivial`, `Small Scope`, `Complex`, `Investigative`. Flag legacy values like `QUICK`, `quick`, `trivial` (wrong case).

**Duplicate timestamps** — flag any `ts` value that appears more than once.

Report: total valid lines, total violations broken down by type, and the line numbers of every offending entry.

---

## Step 4 — Behavioral analytics

Analyze valid entries only. Surface the following:

**Anomalies (show prominently if any exist):**
- `all_tests_passed` is `false`
- `spiked: true` and `spike_resolved: false`
- `plan_deviations` > 2
- Unaccounted risks: `risks_identified - risks_mitigated - risks_out_of_scope - risks_ask_user` > 0
- `escalated: true` without a corresponding `escalated_from` value

**Triage accuracy:**
- Tasks labeled `Trivial` where `files_changed + files_created` > 3 or `plan_deviations` > 0
- Tasks labeled `Small Scope` where `files_changed + files_created` > 5

**Test health trend:**
- Rolling weekly ratio of `tests_written` / (`tests_written` + `tests_fixed`)
- A declining ratio means more fixing than writing — flag if it drops below 0.5 for two consecutive weeks

**Risk hygiene by project and language:**
- Which `project` and `language` values have the highest unmitigated risk counts

**Weekly summary (current week):**
- Task count, triage distribution (%), pass rate, avg `files_changed`, avg `duration_min` (where not null)

**4-week trend comparison:**
- Compare current week to the prior 4 weeks on: pass rate, avg `plan_deviations`, triage distribution
- Flag any metric that has worsened for 2+ consecutive weeks

---

## Step 5 — Output

Write the full report as a markdown file to:
`/mnt/PBT/pbt-audit-reports/YYYY-MM-DD.md`

Create the directory if it doesn't exist. Structure the report as:

```
# PBT Audit — [date]

## Backups
[local backup path + Drive upload status]

## ⚠ Anomalies
[if none: "None detected"]

## Schema Health
[violation summary by type with line numbers]

## Behavioral Analytics
[weekly summary, triage accuracy, test health, risk hygiene, 4-week trend]

## Raw Stats
[total entries, date range, projects covered]
```

Then display a condensed summary in this conversation so I can ask follow-up questions about any section.

---

## Schedule

Set this task to run every **Monday at 9:00 AM**. Type `/schedule` to configure the cadence.

**Important:** This task requires the computer to be awake and Claude Desktop to be open at run time. A LaunchAgent on the Mac automatically mirrors `~/.pbt-log.jsonl` → `~/PBT/.pbt-log.jsonl` every 15 minutes, so no manual file copying is needed — just ensure the Claude Desktop connector for this chat has `~/PBT/` mounted as `/mnt/PBT/`.
