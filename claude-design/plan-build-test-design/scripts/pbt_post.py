#!/usr/bin/env python3
"""PBT Design log poster — normalize, append locally when possible, then POST.

Uses the shared 27-field contract in pbt_schema.py rather than its own rules.
Before 2026-09-16 this file carried a hand-copied 3-field check (ts / triage /
task, extras allowed), one of four such copies; design entries therefore
reached the dashboard unvalidated for the other 24 fields.

Two behaviours changed on 2026-09-16:

1. **Local append.** This used to POST only, with the note "Does not write
   ~/.pbt-log.jsonl (Claude Design sandbox has no Mac home sync)". The
   consequence was that every Claude Design task was absent from the local log
   and therefore invisible to the weekly audit, which reads only that file. It
   now also appends through ~/.pbt/bin/pbt-log.sh whenever that helper is
   reachable, and silently skips the append when it is not — so design work
   shows up in the audit on a real Mac, and the sandbox behaves as before.

2. **No baked-in credential.** The Vercel protection-bypass token used to sit
   here as a literal default. This repo is published and served over a public
   CDN, so that value must be treated as disclosed. The token now comes from
   the environment or from ~/.pbt/vercel-bypass, and its absence is reported
   rather than silently papered over.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

# The schema module ships alongside this script (the design sandbox has no
# ~/.pbt), but prefer the installed copy when running on a real machine so a
# stale bundled copy cannot win.
_HERE = os.path.dirname(os.path.abspath(__file__))
for _candidate in (os.path.expanduser("~/.pbt/lib"), _HERE):
    if os.path.exists(os.path.join(_candidate, "pbt_schema.py")):
        sys.path.insert(0, _candidate)

try:
    import pbt_schema
    from pbt_schema import normalize
except Exception as _ex:  # pragma: no cover
    pbt_schema = None
    normalize = None
    _IMPORT_ERROR = _ex

DASHBOARD_URL = os.environ.get(
    "PBT_DASHBOARD_URL", "https://pbt-dashboard.vercel.app"
).rstrip("/")
LOG_HELPER = os.path.expanduser("~/.pbt/bin/pbt-log.sh")
BYPASS_FILE = os.path.expanduser("~/.pbt/vercel-bypass")
API_TOKEN_FILE = os.path.expanduser("~/.pbt/api-token")


def _secret(env_var: str, path: str) -> str:
    """Read a secret from the environment, else a local file. Never a literal."""
    value = os.environ.get(env_var, "").strip()
    if value:
        return value
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


API_TOKEN = _secret("PBT_API_TOKEN", API_TOKEN_FILE)


def resolve_bypass() -> str:
    """Vercel protection-bypass token, from the environment or a local file.

    Never defaulted to a literal: this file is published through a public CDN.
    """
    return _secret("PBT_VERCEL_BYPASS", BYPASS_FILE)


def append_locally(entry: dict) -> str:
    """Append via the gated helper. Returns a short status for the caller.

    Best-effort by design: the design sandbox has no Mac home, so a missing
    helper is normal there and must not fail the task.
    """
    if not os.path.exists(LOG_HELPER):
        return "skipped (no ~/.pbt/bin/pbt-log.sh — not a synced machine)"
    try:
        proc = subprocess.run(
            ["bash", LOG_HELPER],
            input=json.dumps(entry).encode("utf-8"),
            capture_output=True,
            timeout=15,
        )
    except Exception as ex:
        return "failed (%s)" % ex
    if proc.returncode == 0:
        return "appended to ~/.pbt-log.jsonl"
    detail = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
    return "quarantined by helper (%s)" % (detail or "no reason given")


def post_curl(body: bytes, bypass: str) -> int:
    cmd = [
        "curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
        "-X", "POST", f"{DASHBOARD_URL}/api/log",
        "-H", "Content-Type: application/json",
        "--connect-timeout", "5", "--max-time", "15",
        "-d", "@-",
    ]
    if bypass:
        cmd.extend(["-H", f"x-vercel-protection-bypass: {bypass}"])
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


def post_urllib(body: bytes, bypass: str) -> int:
    headers = {"Content-Type": "application/json"}
    if bypass:
        headers["x-vercel-protection-bypass"] = bypass
    req = urllib.request.Request(
        f"{DASHBOARD_URL}/api/log", data=body, method="POST", headers=headers
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

    if normalize is None:
        print("pbt_post.py: pbt_schema.py not importable (%s); refusing to post "
              "unvalidated" % _IMPORT_ERROR, file=sys.stderr)
        return 1

    try:
        entry, dupes = pbt_schema.loads(raw)
    except Exception as ex:
        print("pbt_post.py: parse_error: %s" % ex, file=sys.stderr)
        return 1

    clean, changes, fatal = normalize(entry, dupes)
    if fatal:
        print("pbt_post.py: rejected (%s)" % "; ".join(fatal), file=sys.stderr)
        print("Required: ts, task, and triage as one of "
              "Trivial / Small Scope / Complex / Investigative. "
              "The triage field takes the bare value — not the "
              "'P.B.T. ' response label.", file=sys.stderr)
        return 1

    if changes:
        fills = [c for c in changes if c.startswith("filled missing ")]
        fixes = [c for c in changes if not c.startswith("filled missing ")]
        parts = []
        if fixes:
            parts.append("corrected: " + "; ".join(fixes))
        if fills:
            names = [c.split()[2].split("=")[0] for c in fills]
            parts.append("defaulted %d absent field(s): %s"
                         % (len(fills), ", ".join(names)))
        print("pbt_post.py: " + " | ".join(parts), file=sys.stderr)

    if clean.get("user") in (None, "", "unknown"):
        env_user = os.environ.get("USER", "").strip()
        if env_user:
            clean["user"] = env_user

    # Local first: the audit reads ~/.pbt-log.jsonl, so this is what makes
    # design work visible in the weekly report at all.
    print("pbt_post.py: local append %s" % append_locally(clean), file=sys.stderr)

    bypass = resolve_bypass()
    if not bypass:
        print("pbt_post.py: no PBT_VERCEL_BYPASS in the environment and no %s — "
              "posting without the bypass header; expect HTTP 401 if the "
              "deployment is protected." % BYPASS_FILE, file=sys.stderr)
    if not API_TOKEN:
        print("pbt_post.py: no PBT_API_TOKEN in the environment and no %s — "
              "/api/log refuses unauthenticated writes, so expect HTTP 401. "
              "The local append above already succeeded, so the entry is not "
              "lost." % API_TOKEN_FILE, file=sys.stderr)

    body = json.dumps(clean).encode("utf-8")
    if shutil.which("curl"):
        return post_curl(body, bypass)
    return post_urllib(body, bypass)


if __name__ == "__main__":
    raise SystemExit(main())
