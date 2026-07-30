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
export PBT_API_TOKEN="${PBT_API_TOKEN:-}"
export PBT_VERCEL_BYPASS="${PBT_VERCEL_BYPASS:-uuN7ItKyFWWg5ypAFwWBjhqFJIkxiv6d}"

LOG_FILE="$HOME/.pbt-log.jsonl"
STATE_FILE="$HOME/.pbt-sync-state"
ERR_LOG="$HOME/.pbt-sync-errors.log"
LOCK_DIR="$HOME/.pbt-sync.lock"
MAX_PER_RUN=200

[ -f "$LOG_FILE" ] || exit 0

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
