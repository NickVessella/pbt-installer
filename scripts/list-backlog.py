#!/usr/bin/env python3
"""List the PBT behavioural backlog from ~/.pbt-log.jsonl.

Read-only. Regenerates the list every run, because line numbers shift whenever
the log is repaired or rewritten — a hardcoded list of line numbers goes stale
immediately and sends you to the wrong entries.

These are NOT data defects; the log is schema-clean. Each item needs a
judgement call:

  spikes            almost certainly resolved and never marked. Close in bulk.
  failed test runs  confirm the underlying failure is fixed, then annotate.
  unaccounted risks close out or reclassify.
  triage mislabels  forward-only. Rewriting historical labels would destroy
                    the signal that labelling drifts.

    python3 scripts/list-backlog.py
"""

import json, sys, os
sys.path.insert(0, os.path.expanduser("~/.pbt/lib"))
LOG = os.path.expanduser("~/.pbt-log.jsonl")
rows = []
for i, l in enumerate(open(LOG, encoding="utf-8"), 1):
    s = l.strip()
    if s:
        e = json.loads(s); e["_line"] = i; rows.append(e)

def show(title, items, fmt):
    print("\n## %s — %d" % (title, len(items)))
    for e in items: print("  L%-5d %s  %-38s %s" % (e["_line"], e["ts"][:10], str(e["project"])[:38], fmt(e)))

show("Unresolved spikes", [e for e in rows if e.get("spiked") and not e.get("spike_resolved")],
     lambda e: str(e["task"])[:68])
show("Failed test runs", [e for e in rows if e.get("all_tests_passed") is False],
     lambda e: str(e["task"])[:68])
open_risk = []
for e in rows:
    r = (e.get("risks_identified") or 0) - (e.get("risks_mitigated") or 0) \
        - (e.get("risks_out_of_scope") or 0) - (e.get("risks_ask_user") or 0)
    if r > 0: e["_open"] = r; open_risk.append(e)
show("Unaccounted risks", open_risk, lambda e: "open=%d  %s" % (e["_open"], str(e["task"])[:56]))
mis = [e for e in rows if (e.get("triage") == "Trivial" and ((e.get("files_changed") or 0)+(e.get("files_created") or 0) > 3 or (e.get("plan_deviations") or 0) > 0))
       or (e.get("triage") == "Small Scope" and (e.get("files_changed") or 0)+(e.get("files_created") or 0) > 5)]
print("\n## Triage mislabels — %d (forward-only; do NOT rewrite history)" % len(mis))
print("  most recent 8:")
for e in mis[-8:]:
    print("  L%-5d %s  %-14s files=%-5d %s" % (e["_line"], e["ts"][:10], e["triage"],
          (e.get("files_changed") or 0)+(e.get("files_created") or 0), str(e["task"])[:48]))
