#!/usr/bin/env python3
"""Sync shared/ source files into install.sh's heredocs.

`install.sh` is shipped via `curl | bash`, so it has to be self-contained —
the heredocs are the artifact that actually reaches a machine. `shared/` holds
the same files in readable, editable, lintable form. Keeping the two in step
was a manual step documented in README ("sync into install.sh heredocs after
edits"), and it drifted: on 2026-09-15 the write path was hardened in the
deployed copies while install.sh kept shipping the old version, so the next
install would have silently reverted every fix.

This makes that sync mechanical. Run it after editing anything in shared/,
then commit both.

    python3 scripts/sync-shared-into-install.py            # write
    python3 scripts/sync-shared-into-install.py --check     # CI: exit 1 if stale

A heredoc is matched by its marker and replaced between the `<<'MARKER'` line
and the lone `MARKER` terminator. Body content is never interpreted, so a
payload containing `$`, backticks or quotes is safe — the markers are all
single-quoted in install.sh, which makes them literal.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
INSTALL = os.path.join(REPO, "install.sh")

# heredoc marker -> path under the repo
MAPPING = {
    # All five schema copies derive from one file. Before this, the same
    # 27-field contract lived in five hand-maintained places.
    "PBT_SCHEMA_EOF": "shared/log-schema.md",
    "SCHEMA_EOF": "shared/log-schema.md",
    "CLAUDE_SCHEMA_EOF": "shared/log-schema.md",
    "PBT_LOG_EOF": "shared/bin/pbt-log.sh",
    "PBT_SYNC_EOF": "shared/bin/pbt-sync.sh",
    "PBT_SCHEMA_PY_EOF": "shared/lib/pbt_schema.py",
    "PBT_LINT_EOF": "shared/bin/pbt-lint.py",
    # The design skill is shipped as a ZIP built from heredocs too, so it
    # drifts the same way. Its schema copy and poster come from here.
    "DESIGN_SCHEMA_EOF": "shared/log-schema.md",
    "DESIGN_POST_EOF": "claude-design/plan-build-test-design/scripts/pbt_post.py",
}

# Files whose content must not contain their own terminator, or the heredoc
# would end early. Checked rather than assumed.
def guard(marker, body, source):
    for lineno, line in enumerate(body.splitlines(), 1):
        if line.strip() == marker:
            sys.exit(
                "%s line %d is exactly %r, which would terminate the heredoc "
                "early. Rename the marker or the line." % (source, lineno, marker)
            )


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8") as fh:
        return fh.read()


def splice(text, marker, body):
    """Replace the body between <<'MARKER' and the lone MARKER terminator."""
    pattern = re.compile(
        r"(<<'%s'\n)(.*?)(^%s$)" % (re.escape(marker), re.escape(marker)),
        re.DOTALL | re.MULTILINE,
    )
    match = pattern.search(text)
    if not match:
        return None, False
    if not body.endswith("\n"):
        body += "\n"
    replacement = match.group(1) + body + match.group(3)
    return text[: match.start()] + replacement + text[match.end():], True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if install.sh is out of step; change nothing")
    args = ap.parse_args()

    original = open(INSTALL, encoding="utf-8").read()
    text = original
    missing = []

    for marker, source in MAPPING.items():
        path = os.path.join(REPO, source)
        if not os.path.exists(path):
            missing.append(source)
            continue
        body = read(source)
        guard(marker, body, source)
        new_text, found = splice(text, marker, body)
        if not found:
            missing.append("heredoc %s not present in install.sh" % marker)
            continue
        text = new_text

    if missing:
        for item in missing:
            print("  missing: %s" % item, file=sys.stderr)
        return 1

    if text == original:
        print("install.sh is in step with shared/ (%d heredocs)" % len(MAPPING))
        return 0

    if args.check:
        print("install.sh is STALE relative to shared/ — run "
              "scripts/sync-shared-into-install.py", file=sys.stderr)
        return 1

    with open(INSTALL, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("install.sh updated from shared/ (%d heredocs)" % len(MAPPING))
    return 0


if __name__ == "__main__":
    sys.exit(main())
