#!/bin/bash
#
# PBT dashboard sync — shared by Cursor stop hook and Claude Code Stop hook
#
# Syncs any log entries in
# ~/.pbt-log.jsonl that the dashboard has not yet received, so a transient
# outage (token rotation, redeploy, network) self-heals instead of silently
# losing entries. Tracks progress with a line-offset cursor and only advances
# it on a confirmed 2xx. Fire-and-forget: non-blocking, silent.

set -uo pipefail

export PBT_DASHBOARD_URL="${PBT_DASHBOARD_URL:-https://pbt-dashboard.vercel.app}"

# Paths first — resolve_secret() below writes to ERR_LOG, and `set -u` makes an
# unbound reference fatal.
LOG_FILE="$HOME/.pbt-log.jsonl"
STATE_FILE="$HOME/.pbt-sync-state"
ERR_LOG="$HOME/.pbt-sync-errors.log"
LOCK_DIR="$HOME/.pbt-sync.lock"
MAX_PER_RUN=200

# Secrets: never baked in as literals. This repo is published and served over a
# public CDN, so any default here is disclosed the moment it is committed.
#
# THE FILE WINS OVER THE ENVIRONMENT, which is the opposite of the usual
# convention, and deliberately so. On 2026-09-16 a rotated bypass secret was
# written to ~/.pbt/vercel-bypass and sync kept failing with 401 anyway,
# because ~/.zprofile still exported the old dead value and the original
# `[ -z "$VAR" ] && read-the-file` logic meant the file was never consulted.
# The symptom — an edge 401 with no runtime log — looks nothing like its cause,
# and it costs an hour to find. ~/.pbt/* is the managed, rotatable store; a
# stale export is the known foot-gun. So the file takes precedence and the
# disagreement is reported rather than silently resolved.
resolve_secret() {
  # $1 = var name, $2 = file path
  local var="$1" file="$2" env_val file_val
  eval "env_val=\${$var:-}"
  file_val=""
  [ -r "$file" ] && file_val="$(tr -d '[:space:]' < "$file")"

  if [ -n "$file_val" ] && [ -n "$env_val" ] && [ "$file_val" != "$env_val" ]; then
    printf '%s %s: environment and %s disagree; using the file. Remove the stale export.\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$var" "$file" >> "$ERR_LOG"
    printf 'pbt-sync.sh: %s in the environment differs from %s — using the file. Remove the stale export (check ~/.zprofile, ~/.zshrc).\n' \
      "$var" "$file" >&2
  fi

  if [ -n "$file_val" ]; then
    eval "export $var=\"\$file_val\""
  else
    eval "export $var=\"\$env_val\""
  fi
}

resolve_secret PBT_API_TOKEN     "$HOME/.pbt/api-token"
resolve_secret PBT_VERCEL_BYPASS "$HOME/.pbt/vercel-bypass"

[ -f "$LOG_FILE" ] || exit 0

# Self-healing lint before sync. Catches any entry that reached the log without
# going through pbt-log.sh (four did between 2026-08-19 and 2026-09-15, each
# surviving days until the Monday audit). Normalizing here also stops malformed
# entries being POSTed and rejected — see the HTTP 400 skips for lines 837,
# 1089, 1122 and 1144 in ~/.pbt-sync-errors.log.
#
# pbt-lint.py adjusts STATE_FILE itself if it has to remove a line, so it must
# run BEFORE the cursor is read below. It always exits 0.
# Findings go to ~/PBT/ rather than $HOME because that is the folder the
# Monday audit has mounted — otherwise the audit cannot see what the lint
# caught during the week.
if [ -f "$HOME/.pbt/bin/pbt-lint.py" ]; then
  PBT_LOG_FILE="$LOG_FILE" PBT_SYNC_STATE="$STATE_FILE" \
  PBT_LINT_FINDINGS="$HOME/PBT/.pbt-lint-findings.jsonl" \
    python3 -I "$HOME/.pbt/bin/pbt-lint.py" 2>/dev/null || true
fi

# Single-flight lock with stale reclaim (a killed worker must not wedge sync).
if [ -d "$LOCK_DIR" ] && find "$LOCK_DIR" -maxdepth 0 -mmin +2 >/dev/null 2>&1; then
  rmdir "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0

# Detach the worker so the hook returns immediately.
(
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

  total=$(awk 'END{print NR}' "$LOG_FILE" 2>/dev/null)
  case "$total" in ''|*[!0-9]*) exit 0 ;; esac
  [ "$total" -eq 0 ] && exit 0

  synced=$(cat "$STATE_FILE" 2>/dev/null)
  case "$synced" in ''|*[!0-9]*) synced="" ;; esac
  # First run: treat all but the newest as already synced (history is handled
  # by backfill, not this hook).
  [ -z "$synced" ] && synced=$((total - 1))
  [ "$synced" -lt 0 ] && synced=0
  # Log shrank or was rewritten; clamp to avoid re-posting.
  [ "$synced" -gt "$total" ] && synced=$total

  if [ "$synced" -ge "$total" ]; then
    printf '%s' "$synced" > "$STATE_FILE"
    exit 0
  fi

  posted=0
  i=$((synced + 1))
  while [ "$i" -le "$total" ] && [ "$posted" -lt "$MAX_PER_RUN" ]; do
    line=$(sed -n "${i}p" "$LOG_FILE")

    if [ -z "$line" ]; then
      printf '%s' "$i" > "$STATE_FILE"
      i=$((i + 1))
      continue
    fi

    payload=$(printf '%s' "$line" | python3 -c "
import sys, json, os
try:
    e = json.loads(sys.stdin.read())
except Exception:
    sys.exit(3)
if not e.get('user'):
    e['user'] = os.environ.get('USER', 'unknown')
sys.stdout.write(json.dumps(e))
" 2>/dev/null)

    if [ -z "$payload" ]; then
      printf '%s skip line %s: invalid JSON\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" >> "$ERR_LOG"
      printf '%s' "$i" > "$STATE_FILE"
      i=$((i + 1))
      continue
    fi

    CURL_ARGS=(-s -o /dev/null -w '%{http_code}' -X POST "${PBT_DASHBOARD_URL}/api/log"
      -H "Content-Type: application/json"
      --connect-timeout 5 --max-time 10)
    [ -n "$PBT_API_TOKEN" ] && CURL_ARGS+=(-H "Authorization: Bearer $PBT_API_TOKEN")
    [ -n "$PBT_VERCEL_BYPASS" ] && CURL_ARGS+=(-H "x-vercel-protection-bypass: $PBT_VERCEL_BYPASS")

    code=$(printf '%s' "$payload" | curl "${CURL_ARGS[@]}" -d @-)
    curl_rc=$?

    if [ "$curl_rc" -ne 0 ]; then
      printf '%s retry later at line %s: curl exit %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" "$curl_rc" >> "$ERR_LOG"
      break
    fi

    case "$code" in
      200|201)
        printf '%s' "$i" > "$STATE_FILE"
        posted=$((posted + 1))
        i=$((i + 1))
        ;;
      400)
        # Malformed entry per server validation — skip permanently so one bad
        # line never blocks the queue.
        printf '%s skip line %s: HTTP 400 (invalid entry)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" >> "$ERR_LOG"
        printf '%s' "$i" > "$STATE_FILE"
        i=$((i + 1))
        ;;
      *)
        # Auth/protection/rate-limit/server error — environmental and
        # transient. Stop and retry on the next stop event.
        printf '%s retry later at line %s: HTTP %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" "$code" >> "$ERR_LOG"
        break
        ;;
    esac
  done
) >/dev/null 2>&1 &

exit 0

