#!/bin/bash
#
# PBT Log Repair
#
# Non-destructive repair of ~/.pbt-log.jsonl.
# Backs up the log first, then fixes:
#   - Multi-line JSON blocks (reassembled via brace-depth buffering)
#   - Alias drift (timestamp→ts, tier→triage, files_touched→files_changed, goal→task)
#   - Enum casing (trivial→Trivial, small_scope→Small Scope, etc.)
#   - Wrong field types (files_changed as list → integer count)
#   - Missing required fields (filled with schema defaults)
#
# Usage:
#   bash repair-log.sh
#   bash repair-log.sh /path/to/other.jsonl

set -euo pipefail

LOG_FILE="${1:-$HOME/.pbt-log.jsonl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup-log.sh"

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }

if [ ! -f "$LOG_FILE" ]; then
  red "Log file not found: $LOG_FILE"
  exit 1
fi

# Step 1: Mandatory backup before any modification
if [ -f "$BACKUP_SCRIPT" ]; then
  bash "$BACKUP_SCRIPT" "$LOG_FILE"
else
  yellow "⚠ backup-log.sh not found at $BACKUP_SCRIPT — creating inline backup"
  TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
  cp "$LOG_FILE" "${LOG_FILE}.bak.${TIMESTAMP}"
  green "✓ Inline backup → ${LOG_FILE}.bak.${TIMESTAMP}"
fi

echo ""
green "▸ Running repair on $LOG_FILE"

python3 - "$LOG_FILE" <<'PYEOF'
import sys, json, os

LOG_PATH = sys.argv[1]

VALID_TRIAGE = {"Trivial", "Small Scope", "Complex", "Investigative"}
TRIAGE_NORMALIZE = {
    "trivial": "Trivial",
    "small": "Small Scope",
    "small scope": "Small Scope",
    "small_scope": "Small Scope",
    "smallscope": "Small Scope",
    "complex": "Complex",
    "investigative": "Investigative",
    "quick": "Trivial",
}

ALIAS_MAP = {
    "timestamp": "ts",
    "tier": "triage",
    "files_touched": "files_changed",
    "goal": "task",
}

SCHEMA_DEFAULTS = {
    "ts": None,
    "user": "unknown",
    "project": "unknown",
    "triage": "Trivial",
    "task": "",
    "files_changed": 0,
    "files_created": 0,
    "tests_written": 0,
    "tests_fixed": 0,
    "all_tests_passed": True,
    "risks_identified": 0,
    "risks_mitigated": 0,
    "risks_out_of_scope": 0,
    "risks_ask_user": 0,
    "stopped_to_ask_user": False,
    "plan_deviations": 0,
    "pre_existing_issues": [],
    "language": None,
    "visual_check": False,
    "visual_issues_found": 0,
    "escalated": False,
    "escalated_from": None,
    "spiked": False,
    "spike_resolved": False,
    "mid_plan_spike": False,
    "duration_min": None,
    "notes": None,
}

ALLOWED_KEYS = set(SCHEMA_DEFAULTS.keys())


def parse_with_brace_buffer(path):
    """Yield (entry_or_none, raw_text) for each logical entry.

    Single-line JSON: yields the parsed dict.
    Multi-line JSON: accumulates lines until brace depth returns to 0.
    Unparseable: yields (None, raw_text) for caller to preserve verbatim.
    """
    with open(path, "r") as f:
        buffer = []
        depth = 0
        in_string = False
        escape = False
        for raw_line in f:
            line = raw_line.rstrip("\n")
            if not line.strip():
                continue
            if not buffer and depth == 0:
                try:
                    obj = json.loads(line)
                    yield obj, line
                    continue
                except json.JSONDecodeError:
                    pass
            buffer.append(line)
            for ch in line:
                if escape:
                    escape = False
                    continue
                if ch == "\\":
                    escape = True
                    continue
                if ch == '"':
                    in_string = not in_string
                    continue
                if in_string:
                    continue
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
            if depth == 0 and buffer:
                joined = "\n".join(buffer)
                try:
                    obj = json.loads(joined)
                    yield obj, joined
                except json.JSONDecodeError:
                    yield None, joined
                buffer = []
                in_string = False
                escape = False
        if buffer:
            yield None, "\n".join(buffer)


def repair_entry(entry):
    """Apply all schema repairs. Returns (repaired_entry, changes_made_list)."""
    changes = []
    repaired = {}

    for k, v in entry.items():
        if k in ALIAS_MAP:
            new_key = ALIAS_MAP[k]
            repaired[new_key] = v
            changes.append(f"alias {k}->{new_key}")
        else:
            repaired[k] = v

    if "triage" in repaired and isinstance(repaired["triage"], str):
        original = repaired["triage"]
        if original not in VALID_TRIAGE:
            normalized = TRIAGE_NORMALIZE.get(original.lower().strip())
            if normalized:
                repaired["triage"] = normalized
                changes.append(f"triage casing {original!r}->{normalized!r}")

    if "files_changed" in repaired and isinstance(repaired["files_changed"], list):
        count = len(repaired["files_changed"])
        repaired["files_changed"] = count
        changes.append(f"files_changed list->int({count})")

    if "files_created" in repaired and isinstance(repaired["files_created"], list):
        count = len(repaired["files_created"])
        repaired["files_created"] = count
        changes.append(f"files_created list->int({count})")

    extra_keys = [k for k in repaired.keys() if k not in ALLOWED_KEYS]
    if extra_keys:
        for k in extra_keys:
            del repaired[k]
        changes.append(f"removed extras {extra_keys}")

    missing = [k for k in SCHEMA_DEFAULTS if k not in repaired]
    if missing:
        for k in missing:
            repaired[k] = SCHEMA_DEFAULTS[k]
        changes.append(f"filled missing {missing}")

    ordered = {k: repaired.get(k, SCHEMA_DEFAULTS[k]) for k in SCHEMA_DEFAULTS}
    return ordered, changes


def main():
    repaired_lines = []
    stats = {
        "total": 0,
        "repaired": 0,
        "unchanged": 0,
        "unparseable": 0,
        "multi_line_assembled": 0,
    }

    for entry, raw in parse_with_brace_buffer(LOG_PATH):
        stats["total"] += 1
        if entry is None:
            stats["unparseable"] += 1
            repaired_lines.append(raw)
            continue
        if "\n" in raw:
            stats["multi_line_assembled"] += 1
        repaired, changes = repair_entry(entry)
        if changes:
            stats["repaired"] += 1
        else:
            stats["unchanged"] += 1
        repaired_lines.append(json.dumps(repaired, ensure_ascii=False))

    tmp_path = LOG_PATH + ".repair.tmp"
    with open(tmp_path, "w") as f:
        for line in repaired_lines:
            f.write(line + "\n")
    os.replace(tmp_path, LOG_PATH)

    print()
    print(f"  Total entries:        {stats['total']}")
    print(f"  Repaired:             {stats['repaired']}")
    print(f"  Unchanged:            {stats['unchanged']}")
    print(f"  Multi-line assembled: {stats['multi_line_assembled']}")
    print(f"  Unparseable (kept):   {stats['unparseable']}")


main()
PYEOF

echo ""
green "✓ Repair complete"
