#!/bin/bash
#
# Backfill existing PBT log entries into the Vercel dashboard.
# Run this once after deploying to seed the dashboard with historical data,
# or with --since to fill a gap (e.g. when the dashboard was offline).
#
# Usage:
#   PBT_DASHBOARD_URL=https://your-app.vercel.app PBT_API_TOKEN=your-token ./backfill.sh
#   PBT_DASHBOARD_URL=https://your-app.vercel.app PBT_API_TOKEN=your-token ./backfill.sh /path/to/other-user.jsonl
#
# Filter to a date range (only entries with ts strictly greater than --since are sent):
#   PBT_DASHBOARD_URL=https://your-app.vercel.app ./backfill.sh --since=2026-04-22T17:00:00Z
#   PBT_DASHBOARD_URL=https://your-app.vercel.app ./backfill.sh --since 2026-04-22T17:00:00Z /path/to/log.jsonl

set -uo pipefail

DASHBOARD_URL="${PBT_DASHBOARD_URL:?Set PBT_DASHBOARD_URL}"
API_TOKEN="${PBT_API_TOKEN:-}"
VERCEL_BYPASS="${PBT_VERCEL_BYPASS:-}"
SINCE=""

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --since=*)
      SINCE="${1#--since=}"
      shift
      ;;
    --since)
      if [ $# -lt 2 ]; then
        echo "Error: --since requires a value" >&2
        exit 2
      fi
      SINCE="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

LOG_FILE="${POSITIONAL[0]:-$HOME/.pbt-log.jsonl}"

if [ ! -f "$LOG_FILE" ]; then
  echo "Log file not found: $LOG_FILE" >&2
  exit 1
fi

TOTAL=$(wc -l < "$LOG_FILE" | tr -d ' ')
if [ -n "$SINCE" ]; then
  echo "Backfilling entries from $LOG_FILE to $DASHBOARD_URL (filter: ts > $SINCE)"
else
  echo "Backfilling $TOTAL entries from $LOG_FILE to $DASHBOARD_URL"
fi

AUTH_ARGS=()
[ -n "$API_TOKEN" ] && AUTH_ARGS+=(-H "Authorization: Bearer $API_TOKEN")
[ -n "$VERCEL_BYPASS" ] && AUTH_ARGS+=(-H "x-vercel-protection-bypass: $VERCEL_BYPASS")

SUCCESS=0
FAILED=0
SKIPPED=0

export SINCE

while IFS= read -r line; do
  [ -z "$line" ] && continue

  # Filter + normalize via python; emit one of:
  #   stdout payload   -> ready to POST
  #   "__SKIP__"       -> excluded by --since
  #   ""               -> parse error
  RESULT=$(printf '%s' "$line" | python3 -c "
import sys, json, os
since = os.environ.get('SINCE') or ''
try:
    entry = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
ts = entry.get('ts') or ''
if since and ts <= since:
    print('__SKIP__')
    sys.exit(0)
if not entry.get('user'):
    entry['user'] = os.environ.get('USER', 'unknown')
print(json.dumps(entry))
" 2>/dev/null)

  if [ -z "$RESULT" ]; then
    FAILED=$((FAILED + 1))
    printf "\r  posted: %d  failed: %d  skipped: %d / %d" "$SUCCESS" "$FAILED" "$SKIPPED" "$TOTAL"
    continue
  fi
  if [ "$RESULT" = "__SKIP__" ]; then
    SKIPPED=$((SKIPPED + 1))
    printf "\r  posted: %d  failed: %d  skipped: %d / %d" "$SUCCESS" "$FAILED" "$SKIPPED" "$TOTAL"
    continue
  fi

  HTTP_CODE=$(printf '%s' "$RESULT" | curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${DASHBOARD_URL}/api/log" \
    -H "Content-Type: application/json" \
    "${AUTH_ARGS[@]}" \
    -d @- 2>/dev/null) || HTTP_CODE="000"

  if [ "$HTTP_CODE" = "201" ]; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAILED=$((FAILED + 1))
  fi

  printf "\r  posted: %d  failed: %d  skipped: %d / %d" "$SUCCESS" "$FAILED" "$SKIPPED" "$TOTAL"
done < "$LOG_FILE"

echo ""
echo "Done: $SUCCESS succeeded, $FAILED failed, $SKIPPED skipped (out of $TOTAL)"
