#!/usr/bin/env python3
"""One-off: backfill `user` on entries where it is "unknown".

Dry-run by default; nothing is written without --apply.

Why this is safe, and why it is the ONLY backfill being done:

    Exactly one user has ever appeared in this log — nick.vessella, on 1,251
    entries. There is no second candidate, so filling the remaining "unknown"
    values is arithmetic rather than inference.

`project` and `language` are deliberately left alone. Time-neighbour
agreement recovers project at 112-for / 92-against, i.e. ~55% accuracy, which
would plant roughly 92 wrong attributions. A wrong project silently skews
per-project risk and triage analysis, whereas "unknown" is honestly excluded
from it — so guessing is strictly worse than not knowing. It would also move
the emitter-quality baseline and destroy the ability to tell whether the
emitter is actually improving.

Every change is recorded in the entry's [pbt-salvage] block as
`_user_backfilled`, so this pass is auditable and distinguishable from data
the emitter actually supplied.

Usage:
    python3 scripts/backfill-user.py --log ~/.pbt-log.jsonl
    python3 scripts/backfill-user.py --log ~/.pbt-log.jsonl --apply
"""

import argparse
import collections
import datetime
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "shared", "lib"))
sys.path.insert(0, os.path.expanduser("~/.pbt/lib"))

import pbt_schema  # noqa: E402
from pbt_schema import SALVAGE_TAG, violations  # noqa: E402

UNKNOWN = "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=os.path.expanduser("~/.pbt-log.jsonl"))
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    path = os.path.expanduser(args.log)
    if not os.path.exists(path):
        sys.exit("log not found: %s" % path)

    with open(path, encoding="utf-8", errors="surrogatepass") as fh:
        lines = fh.read().splitlines()

    rows = []
    for lineno, raw in enumerate(lines, 1):
        s = raw.strip()
        if not s:
            continue
        try:
            rows.append((lineno, json.loads(s)))
        except Exception as ex:
            sys.exit("line %d is not valid JSON (%s) — run pbt-repair.py first" % (lineno, ex))

    known = collections.Counter(
        e["user"] for _, e in rows if e.get("user") and e["user"] != UNKNOWN
    )
    if len(known) != 1:
        sys.exit(
            "refusing to backfill: expected exactly one known user, found %d (%s).\n"
            "This script is only safe when the log has a single author."
            % (len(known), dict(known))
        )
    target, count = known.most_common(1)[0]

    targets = [(lineno, e) for lineno, e in rows if e.get("user") == UNKNOWN]

    print("log:            %s" % path)
    print("entries:        %d" % len(rows))
    print("sole known user: %r (%d entries)" % (target, count))
    print("to backfill:    %d entries where user == 'unknown'" % len(targets))
    if targets:
        span = (targets[0][1]["ts"][:10], targets[-1][1]["ts"][:10])
        print("date span:      %s .. %s" % span)
        print("still unknown after this pass (untouched on purpose):")
        for f in ("project", "language"):
            n = sum(1 for _, e in rows if e.get(f) == UNKNOWN)
            print("  %-9s %d" % (f, n))

    if not targets:
        print("\nnothing to do.")
        return 0

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for _lineno, entry in targets:
        entry["user"] = target
        notes = entry.get("notes")
        block = "%s %s" % (
            SALVAGE_TAG,
            json.dumps({"_user_backfilled": {"from": UNKNOWN, "at": stamp}},
                       separators=(",", ":")),
        )
        entry["notes"] = ("%s %s" % (notes, block)) if notes else block

    bad = [(lineno, violations(e)) for lineno, e in rows if violations(e)]
    if bad:
        print("\n!! %d entries would violate the schema after the change:" % len(bad))
        for lineno, v in bad[:5]:
            print("   line %d: %s" % (lineno, v[:3]))
        sys.exit(1)
    print("schema check:   all %d entries still valid" % len(rows))

    if not args.apply:
        print("\nDRY RUN — nothing written. Re-run with --apply.")
        return 0

    backup = "%s.pre-user-backfill_%s" % (
        path, datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S"))
    shutil.copy2(path, backup)
    print("\nbackup:  %s" % backup)

    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8", errors="surrogatepass") as fh:
            for _lineno, entry in rows:
                fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print("rewrote: %s (%d entries, %d backfilled)" % (path, len(rows), len(targets)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
