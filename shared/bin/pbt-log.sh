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

# Derive the attribution fields the agent keeps forgetting.
#
# `user` and `project` are mechanically knowable at write time — this script
# runs on the developer's machine, in the task's working directory — yet
# SKILL.md asked the MODEL to supply them, making them something an LLM can
# omit. It did, on 15-18% of entries (46% in one week), and each omission
# became "unknown", which silently drops the task out of every per-project and
# per-person report. As of 2026-09-17: 204 entries with no project.
#
# So the helper now works them out itself. A field you never have to supply is
# a field you cannot forget. Values the agent DID provide always win; these are
# a floor, not an override.
#
# `project` is taken only from a git root. Falling back to $(basename $PWD)
# would cheerfully record "nick.vessella" for anything run from $HOME, and a
# confidently wrong project is worse than a known-absent one.
#
# `language` is deliberately NOT derived: only the agent knows what it changed.
# It stays the emitter's responsibility and stays measured.
PBT_DERIVED_USER="$(whoami 2>/dev/null || true)"
PBT_DERIVED_PROJECT=""
if _git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  [ -n "$_git_root" ] && PBT_DERIVED_PROJECT="$(basename "$_git_root")"
fi
export PBT_DERIVED_USER PBT_DERIVED_PROJECT

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

# Fill the derived attribution fields BEFORE normalizing, so the schema sees a
# real value rather than defaulting to "unknown". Only ever fills a gap — an
# agent-supplied value is never overwritten.
_derived = []
for _field, _env in (("user", "PBT_DERIVED_USER"), ("project", "PBT_DERIVED_PROJECT")):
    _value = os.environ.get(_env, "").strip()
    if _value and entry.get(_field) in (None, "", "unknown"):
        entry[_field] = _value
        _derived.append(_field)

clean, changes, fatal = normalize(entry, dupes)
if fatal:
    sys.stdout.write("FATAL:" + "; ".join(fatal))
    sys.exit(0)

# Record that the helper supplied these, not the agent. The value is correct
# either way, but the audit has to be able to tell a well-formed payload from
# one the safety net rescued — otherwise the fallback quietly hides a
# regression in the emitter, which is the same trap normalization itself set.
if _derived and clean is not None:
    _block = "%s %s" % (
        pbt_schema.SALVAGE_TAG,
        json.dumps({"_derived_by_helper": _derived}, separators=(",", ":")),
    )
    clean["notes"] = ("%s %s" % (clean["notes"], _block)) if clean.get("notes") else _block
    changes.append("derived %s from the environment" % ", ".join(_derived))
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
