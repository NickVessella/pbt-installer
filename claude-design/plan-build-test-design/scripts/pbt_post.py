#!/usr/bin/env python3
"""PBT Design log poster — validate then POST to the dashboard.

Mirrors ~/.pbt/bin/pbt-log.sh gate rules and dashboard/api/log.js:
  required ts, triage (exact enum), task; extras allowed; no alias rename.
Does not write ~/.pbt-log.jsonl (Claude Design sandbox has no Mac home sync).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

VALID_TIERS = {"Trivial", "Small Scope", "Complex", "Investigative"}
DASHBOARD_URL = os.environ.get(
    "PBT_DASHBOARD_URL", "https://pbt-dashboard.vercel.app"
).rstrip("/")
BYPASS = os.environ.get(
    "PBT_VERCEL_BYPASS", "uuN7ItKyFWWg5ypAFwWBjhqFJIkxiv6d"
)
API_TOKEN = os.environ.get("PBT_API_TOKEN", "")


def validate(entry: object) -> list[str]:
    if not isinstance(entry, dict):
        return ["parse_error: body must be a JSON object"]
    problems: list[str] = []
    if not entry.get("ts"):
        problems.append("missing ts")
    triage = entry.get("triage")
    if not triage:
        problems.append("missing triage")
    elif triage not in VALID_TIERS:
        problems.append("invalid triage: %r" % (triage,))
    if not entry.get("task"):
        problems.append("missing task")
    return problems


def post_curl(body: bytes) -> int:
    cmd = [
        "curl",
        "-sS",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "-X",
        "POST",
        f"{DASHBOARD_URL}/api/log",
        "-H",
        "Content-Type: application/json",
        "-H",
        f"x-vercel-protection-bypass: {BYPASS}",
        "--connect-timeout",
        "5",
        "--max-time",
        "15",
        "-d",
        "@-",
    ]
    if API_TOKEN:
        cmd.extend(["-H", f"Authorization: Bearer {API_TOKEN}"])
    proc = subprocess.run(cmd, input=body, capture_output=True, timeout=20)
    if proc.returncode != 0:
        err = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
        print(f"pbt_post.py: curl failed: {err or proc.returncode}", file=sys.stderr)
        return 1
    code = (proc.stdout or b"").decode("utf-8", errors="replace").strip()
    if code not in ("200", "201"):
        print(f"pbt_post.py: HTTP {code}", file=sys.stderr)
        return 1
    print(f"pbt_post.py: ok HTTP {code}")
    return 0


def post_urllib(body: bytes) -> int:
    req = urllib.request.Request(
        f"{DASHBOARD_URL}/api/log",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-vercel-protection-bypass": BYPASS,
        },
    )
    if API_TOKEN:
        req.add_header("Authorization", f"Bearer {API_TOKEN}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            code = resp.getcode()
            resp.read()
    except urllib.error.HTTPError as e:
        print(f"pbt_post.py: HTTP {e.code}", file=sys.stderr)
        try:
            print(e.read().decode("utf-8", errors="replace"), file=sys.stderr)
        except Exception:
            pass
        return 1
    except Exception as ex:
        print(f"pbt_post.py: request failed: {ex}", file=sys.stderr)
        return 1
    if code not in (200, 201):
        print(f"pbt_post.py: unexpected HTTP {code}", file=sys.stderr)
        return 1
    print(f"pbt_post.py: ok HTTP {code}")
    return 0


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        print("pbt_post.py: empty stdin", file=sys.stderr)
        return 1
    try:
        entry = json.loads(raw)
    except Exception as ex:
        print("pbt_post.py: parse_error: %s" % ex, file=sys.stderr)
        return 1

    problems = validate(entry)
    if problems:
        print("pbt_post.py: rejected (%s)" % "; ".join(problems), file=sys.stderr)
        print(
            "Use exact field names: ts, triage, task — never timestamp/tier/goal.",
            file=sys.stderr,
        )
        return 1

    if not entry.get("user"):
        entry["user"] = os.environ.get("USER", "unknown")

    body = json.dumps(entry).encode("utf-8")
    if shutil.which("curl"):
        return post_curl(body)
    return post_urllib(body)


if __name__ == "__main__":
    raise SystemExit(main())
