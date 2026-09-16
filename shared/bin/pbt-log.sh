#!/bin/bash
# PBT log helper — appends a single JSON line from stdin to the PBT log.
# Called by the agent via: echo '{"ts":"..."}' | ~/.pbt/bin/pbt-log.sh
# Using a fixed-name script lets Cursor IDE allowlist it once.
#
# CHANGED 2026-09-15: validation moved from a 3-field check (ts / triage / task)
# to the full schema in ~/.pbt/lib/pbt_schema.py, and the behaviour changed from
# reject-or-append to NORMALIZE-then-append.
#
# Rationale: the old gate accepted 114 of the 118 malformed entries that
# accumulated in the log between Feb and Sep 2026, because it checked only three
# fields and explicitly allowed extra fields. Missing fields, `files_changed` as
# a list of filenames, and off-schema keys like `outcome` / `result` all passed
# straight through. Normalizing at the choke point fixes the class of problem
# rather than the instances.
#
# Entries are quarantined only when their meaning cannot be recovered
# (unparseable JSON, no ts, no task, unrecognizable triage). Everything else is
# repaired in place and appended, with the repairs reported on stderr so the
# agent — and the human reading the transcript — can see what was corrected.

set -uo pipefail

LOG_FILE="${PBT_LOG_FILE:-$HOME/.pbt-log.jsonl}"
QUARANTINE_FILE="${PBT_QUARANTINE_FILE:-$HOME/.pbt-log-quarantine.jsonl}"
LIB_DIR="${PBT_LIB_DIR:-$HOME/.pbt/lib}"

# Read ALL of stdin, not one line.
#
# The previous `read -r -t 5 line` had three data-loss bugs: pretty-printed
# JSON lost every field but the first line; a caller slower than 5s had its
# entry discarded with exit 0 and no trace at all; and a stall mid-write
# truncated the payload silently. `cat` has no timeout and no line limit, so a
# multi-line payload arrives whole and a slow writer blocks instead of
# vanishing.
line=$(cat)
[ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || exit 0

# Normalize: clean JSON on stdout, "FATAL:<reason>" on stdout if unrecoverable,
# human-readable repair notes on stderr (which passes through to the caller).
#
# `python3 -I` runs isolated: it does NOT put the current working directory on
# sys.path. Without it, a `pbt_schema.py` sitting in whatever repo the agent
# happens to be working in would be imported instead of ours — arbitrary code
# execution on every log write, and a trivial way to corrupt the log.
normalized=$(printf '%s' "$line" | PBT_LIB_DIR="$LIB_DIR" python3 -I -c '
import sys, os, json

sys.path.insert(0, os.environ["PBT_LIB_DIR"])
raw = sys.stdin.read()

try:
    import pbt_schema
    from pbt_schema import normalize
except Exception as ex:
    # Never lose an entry because the validator is missing or broken. Degrade
    # to the old behaviour and say so loudly.
    sys.stderr.write("pbt-log.sh: validator unavailable (%s); appending unvalidated\n" % ex)
    sys.stdout.write(raw)
    sys.exit(0)

try:
    entry, dupes = pbt_schema.loads(raw)
except Exception as ex:
    sys.stdout.write("FATAL:parse_error: %s" % ex)
    sys.exit(0)

clean, changes, fatal = normalize(entry, dupes)
if fatal:
    sys.stdout.write("FATAL:" + "; ".join(fatal))
    sys.exit(0)
if changes:
    # Keep the report readable: list real corrections, summarize default-fills.
    fills = [c for c in changes if c.startswith("filled missing ")]
    fixes = [c for c in changes if not c.startswith("filled missing ")]
    parts = []
    if fixes:
        parts.append("corrected: " + "; ".join(fixes))
    if fills:
        names = [c.split()[2].split("=")[0] for c in fills]
        parts.append("defaulted %d absent field(s): %s" % (len(fills), ", ".join(names)))
    sys.stderr.write("pbt-log.sh: " + " | ".join(parts) + "\n")
sys.stdout.write(json.dumps(clean, ensure_ascii=False))
')

case "${normalized:-}" in
  FATAL:*) fail_reason="${normalized#FATAL:}" ;;
  "")      fail_reason="validation_failed" ;;
  *)
    printf '%s\n' "$normalized" >> "$LOG_FILE"
    exit 0
    ;;
esac

# Unrecoverable — quarantine. Never let the entry vanish with zero trace.
quarantine_payload=$(
  printf '%s' "$line" | PBT_QUARANTINE_REASON="$fail_reason" python3 -I -c '
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

printf 'pbt-log.sh: quarantine write failed (%s); raw payload follows\n%s\n' "$fail_reason" "$line" >&2
exit 1
