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
