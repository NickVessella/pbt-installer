#!/usr/bin/env python3
"""Self-healing lint for ~/.pbt-log.jsonl.

Runs from the task-stop hook (via pbt-sync.sh), so an entry that bypassed
pbt-log.sh is corrected within one task instead of surviving until Monday's
audit. Between 2026-08-19 and 2026-09-15 four such entries reached the log and
each one sat there for days.

Behaviour:
  * fixable entry  -> normalized in place, line count unchanged
  * unparseable    -> moved to ~/.pbt-log-quarantine.jsonl and the line removed
  * nothing wrong  -> exits silently having written nothing

Two things this is careful about:

1. `pbt-sync.sh` tracks dashboard progress with a LINE OFFSET in
   ~/.pbt-sync-state. Removing a line shifts every offset after it, which
   would make sync either re-post or skip entries. So removals are counted and
   the cursor is decremented by however many fell at or before it. Normalizing
   in place keeps the count stable and needs no adjustment.

2. It never rewrites the log unless something actually changed, so the common
   case costs one read.

Exit status is always 0 — a lint failure must not break the user's task.
"""

import json
import os
import sys

sys.path.insert(0, os.environ.get("PBT_LIB_DIR", os.path.expanduser("~/.pbt/lib")))

LOG = os.environ.get("PBT_LOG_FILE", os.path.expanduser("~/.pbt-log.jsonl"))
QUARANTINE = os.environ.get(
    "PBT_QUARANTINE_FILE", os.path.expanduser("~/.pbt-log-quarantine.jsonl")
)
STATE = os.environ.get("PBT_SYNC_STATE", os.path.expanduser("~/.pbt-sync-state"))
FINDINGS = os.environ.get(
    "PBT_LINT_FINDINGS", os.path.expanduser("~/.pbt-lint-findings.jsonl")
)


def main():
    try:
        import pbt_schema
        from pbt_schema import normalize
    except Exception:
        return 0  # validator unavailable; never break the task

    if not os.path.exists(LOG):
        return 0

    try:
        with open(LOG, encoding="utf-8", errors="surrogatepass") as fh:
            raw_lines = fh.read().splitlines()
    except OSError:
        return 0

    kept = []
    removed_indices = []
    findings = []
    dirty = False

    for idx, raw in enumerate(raw_lines, 1):
        stripped = raw.strip()
        if not stripped:
            removed_indices.append(idx)
            dirty = True
            continue

        try:
            entry, dupes = pbt_schema.loads(stripped)
        except Exception as ex:
            removed_indices.append(idx)
            findings.append({"line": idx, "action": "quarantined",
                             "reason": "parse_error: %s" % ex, "raw": stripped})
            dirty = True
            continue

        clean, changes, fatal = normalize(entry, dupes)
        if fatal:
            removed_indices.append(idx)
            findings.append({"line": idx, "action": "quarantined",
                             "reason": "; ".join(fatal), "raw": stripped})
            dirty = True
            continue

        rendered = json.dumps(clean, ensure_ascii=False)
        if rendered != stripped:
            dirty = True
            if changes:
                findings.append({"line": idx, "action": "normalized",
                                 "changes": changes})
        kept.append(rendered)

    if not dirty:
        return 0

    # --- rewrite atomically ------------------------------------------------
    tmp = LOG + ".lint-tmp"
    try:
        with open(tmp, "w", encoding="utf-8", errors="surrogatepass") as fh:
            for line in kept:
                fh.write(line + "\n")
        os.replace(tmp, LOG)
    except Exception:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return 0

    # --- keep the dashboard sync cursor pointing at the same entry ---------
    if removed_indices:
        try:
            cursor = int(open(STATE).read().strip())
        except (OSError, ValueError):
            cursor = None
        if cursor is not None:
            shift = sum(1 for i in removed_indices if i <= cursor)
            if shift:
                with open(STATE, "w") as fh:
                    fh.write(str(max(0, cursor - shift)))

    # --- record what happened, for Monday's audit -------------------------
    quarantine_records = [f for f in findings if f["action"] == "quarantined"]
    if quarantine_records:
        try:
            import datetime
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
            with open(QUARANTINE, "a", encoding="utf-8") as fh:
                for rec in quarantine_records:
                    fh.write(json.dumps({
                        "quarantined_at": stamp,
                        "reason": rec["reason"],
                        "source": "pbt-lint",
                        "entry": {"_raw": rec["raw"]},
                    }, ensure_ascii=False) + "\n")
        except OSError:
            pass

    if findings:
        try:
            import datetime
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            )
            with open(FINDINGS, "a", encoding="utf-8") as fh:
                for rec in findings:
                    rec["at"] = stamp
                    fh.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
        except OSError:
            pass
        sys.stderr.write(
            "pbt-lint: repaired %d log entr%s (%d quarantined); see %s\n"
            % (len(findings), "y" if len(findings) == 1 else "ies",
               len(quarantine_records), FINDINGS)
        )

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # never break the user's task
