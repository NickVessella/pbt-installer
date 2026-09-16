# Handoff — PBT log hardening

**Repo:** `~/RepoFolder/pbt-installer` (`github.com/NickVessella/pbt-installer`)
**State as of 2026-09-16:** `main` is **1 commit ahead of `origin/main`, unpushed**. A second branch holds work that is deliberately not merged yet.

Open this repo in Cursor. Everything below happens here.

---

## Where things live (this trips people up)

The deployed copies are **generated**, not sources. Editing them works until the next `install.sh` run silently reverts it — which is exactly the bug this work fixed.

| You might edit… | Don't. Edit this instead |
|---|---|
| `~/.cursor/skills/plan-build-test/SKILL.md` | the `SKILL_EOF` / `CLAUDE_SKILL_EOF` heredocs in `install.sh` |
| `~/.cursor/rules/plan-build-test.mdc` | the `RULE_EOF` / `CLAUDE_RULE_EOF` heredocs in `install.sh` |
| `~/.pbt/bin/pbt-log.sh`, `pbt-sync.sh`, `pbt-lint.py` | `shared/bin/*` → then run the sync script |
| `~/.pbt/lib/pbt_schema.py`, `~/PBT/lib/pbt_schema.py` | `shared/lib/pbt_schema.py` → then run the sync script |
| `~/.pbt/log-schema.md` (+ 4 other copies) | `shared/log-schema.md` → then run the sync script |
| `dashboard/api/_pbt-schema.js` | `shared/lib/pbt_schema.py` → then run the generator |

`~/.cursor/skills/plan-build-test/` is a local-only git repo with no remote. It is **install output**, not a source of truth. Ignore it.

### After editing anything in `shared/`

```bash
python3 scripts/sync-shared-into-install.py       # rewrites 9 heredocs in install.sh
python3 scripts/generate-dashboard-schema.py      # rewrites dashboard/api/_pbt-schema.js
```

Both take `--check` (exit 1 if stale) and belong in CI. `install.sh` must stay self-contained because it ships via `curl | bash`, so the heredocs *are* the artifact — that manual sync is what drifted before.

**Verify a change actually lands:**

```bash
rm -rf /tmp/pbtcheck && mkdir -p /tmp/pbtcheck
HOME=/tmp/pbtcheck bash install.sh --cursor-only -y
diff /tmp/pbtcheck/.pbt/lib/pbt_schema.py shared/lib/pbt_schema.py   # expect no output
```

---

## Remaining work, in order

### 1. Push `main` — safe, do first

```bash
git push origin main
```

`6655d0e` — full-schema normalization in the write path, `install.sh` no longer able to revert it, design-skill entries now reaching the local log, and the hardcoded Vercel bypass token removed from 7 files. Vercel's git integration deploys `dashboard/` on push.

This is independent of the token work below and carries no auth change.

### 2. Rotate the Vercel protection-bypass token — security, do soon

The old value was committed to this repo, which is served publicly via `cdn.jsdelivr.net/gh/NickVessella/pbt-installer@main/install.sh`. **Treat it as disclosed.** It is still in git history even though it is gone from the working tree.

`pbt-dashboard` is a **Klaviyo enterprise** project (`team_JuYJ1jycjjeaH5vWwyZJffwO`) with `ssoProtection` enabled for all deployments and no password or trusted-IP restriction. The bypass token is therefore the only non-SSO route in — so this is a Klaviyo security matter, not just a key swap. Worth telling their security team.

1. Vercel → `pbt-dashboard` → Settings → Deployment Protection → Protection Bypass for Automation → regenerate
2. `printf '%s' 'NEW_VALUE' > ~/.pbt/vercel-bypass && chmod 600 ~/.pbt/vercel-bypass`

Nothing in code needs changing — `pbt-sync.sh` and `pbt_post.py` already resolve it from env, then that file.

### 3. Set `PBT_API_TOKEN`, then merge the auth branch

Branch **`pbt-api-auth-fail-closed`** (`99f95e1`) makes `/api/log` refuse unauthenticated writes: 503 when the server has no token, 401 on missing/wrong/truncated, constant-time compare.

It is unmerged on purpose. `/api/log` currently reads `if (token) { …require… }` and `PBT_API_TOKEN` has never been set on the project, so **the write endpoint has no application-level auth at all** — Vercel SSO is the only gate.

**Both sides must have the token before merging, or every write 401s:**

1. Vercel → `pbt-dashboard` → Environment Variables → `PBT_API_TOKEN` (Production **and** Preview)
2. Locally:
   ```bash
   bash -c 'read -rsp "Paste PBT_API_TOKEN: " t && printf "%s" "$t" > ~/.pbt/api-token && chmod 600 ~/.pbt/api-token'
   ```
   `~/.pbt/api-token` does **not exist yet** — this is the missing piece.

Note: a Vercel env var marked **Sensitive** shows a padlock and no value in the UI. That is correct behaviour, not a failed save — don't chase it.

Then `git merge pbt-api-auth-fail-closed` and push. Failure mode if you get it wrong is mild: `pbt-sync.sh` treats 401/503 as retryable, so entries queue in `~/.pbt-log.jsonl` and drain once the token is right. Nothing is lost.

**Verify after merge** — POST with no auth header should return 401 (token set) rather than 503 (not set).

### 4. Behavioural backlog — separate, needs judgement not code

19 unresolved spikes (oldest 2026-05-15), 11 failed test runs (all pre-2026-07-27), 7 entries with unaccounted risks, 70 triage mislabels. Not data defects; no script fixes them. See `pbt-remediation-plan-part-two.md` in `~/Documents/Claude/Projects/PBT Audit System/`.

---

## Don't touch

- `dashboard/api/entries.js` and `dashboard/public/index.html` — your own uncommitted WIP, deliberately excluded from `6655d0e`.
- `/api/entries` auth — the dashboard UI calls it with a plain `fetch()` and no header. Adding auth breaks the page. It stays behind Vercel SSO by design.

## Invariants worth keeping

- **Normalize, don't reject.** A gate that discards an agent's work gets bypassed — four entries proved that before the lint existed. Only unparseable JSON, missing `ts`/`task`, or an unrecognizable `triage` should ever be refused.
- **Never silently change a value.** Coercions and dropped keys go into the `[pbt-salvage]` block in `notes` so the original is recoverable.
- **`all_tests_passed` is nullable.** `null` means "not recorded" and must stay out of pass-rate maths. Defaulting it to `true` would have fabricated passes for 92 entries.
- **A clean schema is not a healthy log.** The gate guarantees 27 valid fields, so `violations()` reads zero even when the emitter sends near-empty payloads. `emitter_quality()` is the companion metric — **18% of the log is currently unattributable** (`user`/`project`/`language` = `"unknown"`), which no schema check would ever surface.

## Verification suite

```bash
python3 scripts/sync-shared-into-install.py --check
python3 scripts/generate-dashboard-schema.py --check
node --check dashboard/api/log.js && node --check dashboard/api/_pbt-schema.js
bash -n install.sh
python3 - <<'PY'
import json,sys; sys.path.insert(0,'shared/lib')
from pbt_schema import normalize, violations, salvage_payload
e,ch,f = normalize({"ts":"2026-06-02","triage":"P.B.T. Complex","task":"t","outcome":"x"})
assert not f and not violations(e), (f, violations(e))
p = salvage_payload(e)
assert p["_triage_corrected_from"] == "P.B.T. Complex" and p["ts_original"] == "2026-06-02"
print("schema OK:", len(e), "fields,", sorted(p))
PY
```

Python↔JS normalizer parity was verified across 16 adversarial cases with 0 mismatches; keep that true if you touch either side.
