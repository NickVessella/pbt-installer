#!/bin/bash
# PBT log helper — appends a single JSON line from stdin to the PBT log.
# Called by the agent via: echo '{"ts":"..."}' | ~/.pbt/bin/pbt-log.sh
# Using a fixed-name script lets Cursor IDE allowlist it once.
#
# Validates required fields (ts, triage enum, task) before appending — mirrors
# dashboard/api/log.js. Extra fields are allowed. Invalid or unparseable input
# goes to ~/.pbt-log-quarantine.jsonl and the script exits nonzero.

set -uo pipefail

LOG_FILE="$HOME/.pbt-log.jsonl"
QUARANTINE_FILE="$HOME/.pbt-log-quarantine.jsonl"

read -r -t 5 line || true
[ -n "${line:-}" ] || exit 0

# Validate with python3 (same availability assumption as pbt-stop.sh). Extra
# fields pass through unchanged; only the required trio is checked.
# Prints "OK" on stdout if valid; otherwise prints a reason and exits 1.
reason=$(printf '%s' "$line" | python3 -c '
import sys, json
raw = sys.stdin.read()
VALID = {"Trivial", "Small Scope", "Complex", "Investigative"}
try:
    e = json.loads(raw)
except Exception as ex:
    print("parse_error: " + str(ex))
    sys.exit(1)
if not isinstance(e, dict):
    print("parse_error: body must be a JSON object")
    sys.exit(1)
problems = []
if not e.get("ts"):
    problems.append("missing ts")
triage = e.get("triage")
if not triage:
    problems.append("missing triage")
elif triage not in VALID:
    problems.append("invalid triage: %r" % (triage,))
if not e.get("task"):
    problems.append("missing task")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("OK")
' 2>/dev/null)
rc=$?

if [ "$rc" -eq 0 ] && [ "$reason" = "OK" ]; then
  printf '%s\n' "$line" >> "$LOG_FILE"
  exit 0
fi

# Invalid — quarantine. Never let the entry vanish with zero trace.
fail_reason="${reason:-validation_failed}"
quarantine_payload=$(
  printf '%s' "$line" | PBT_QUARANTINE_REASON="$fail_reason" python3 -c '
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

# Last-resort fallback: quarantine write failed — dump payload to stderr.
printf 'pbt-log.sh: quarantine write failed (%s); raw payload follows\n%s\n' "$fail_reason" "$line" >&2
exit 1
