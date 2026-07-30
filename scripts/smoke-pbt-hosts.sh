#!/usr/bin/env bash
# Local smoke checks for PBT shared gate + Design poster (no install required if bins exist).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_HELPER="${1:-$HOME/.cursor/hooks/pbt-log.sh}"
POST="${ROOT}/claude-design/plan-build-test-design/scripts/pbt_post.py"
BYPASS="${PBT_VERCEL_BYPASS:-uuN7ItKyFWWg5ypAFwWBjhqFJIkxiv6d}"
DASH="${PBT_DASHBOARD_URL:-https://pbt-dashboard.vercel.app}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

fail=0

echo "== Alias via wrapper path (expect quarantine / nonzero) =="
if [ ! -x "$LOG_HELPER" ]; then
  red "missing $LOG_HELPER — run install.sh first"
  exit 1
fi
set +e
echo '{"timestamp":"2026-07-29T00:00:00Z","tier":"Trivial","goal":"alias smoke"}' | "$LOG_HELPER"
alias_rc=$?
set -e
if [ "$alias_rc" -ne 0 ]; then
  green "OK alias rejected rc=$alias_rc"
else
  red "FAIL alias was accepted"
  fail=1
fi

echo "== Valid pipe-log (expect rc=0) =="
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
payload=$(printf '{"ts":"%s","user":"%s","project":"pbt-installer","triage":"Trivial","task":"smoke valid pipe-log","files_changed":0,"files_created":0,"tests_written":0,"tests_fixed":0,"all_tests_passed":true,"risks_identified":0,"risks_mitigated":0,"risks_out_of_scope":0,"risks_ask_user":0,"stopped_to_ask_user":false,"plan_deviations":0,"pre_existing_issues":[],"language":"sh","visual_check":false,"visual_issues_found":0,"escalated":false,"escalated_from":null,"spiked":false,"spike_resolved":false,"mid_plan_spike":false,"duration_min":null,"notes":"smoke"}' "$ts" "${USER:-unknown}")
set +e
printf '%s\n' "$payload" | "$LOG_HELPER"
valid_rc=$?
set -e
if [ "$valid_rc" -eq 0 ]; then
  green "OK valid entry accepted"
else
  red "FAIL valid entry rejected rc=$valid_rc"
  fail=1
fi

echo "== Design pbt_post.py alias reject (no network on reject) =="
set +e
err=$(echo '{"timestamp":"x","tier":"Trivial"}' | python3 "$POST" 2>&1)
post_rc=$?
set -e
if [ "$post_rc" -ne 0 ] && echo "$err" | grep -q 'rejected'; then
  green "OK design alias rejected"
else
  red "FAIL design alias: rc=$post_rc err=$err"
  fail=1
fi

echo "== Design pbt_post.py valid POST (optional live) =="
if [ "${PBT_SMOKE_LIVE:-0}" = "1" ]; then
  ts2=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  set +e
  out=$(printf '{"ts":"%s","user":"%s","project":"pbt-installer","triage":"Trivial","task":"smoke design pbt_post","files_changed":0,"files_created":0,"tests_written":0,"tests_fixed":0,"all_tests_passed":true,"risks_identified":0,"risks_mitigated":0,"risks_out_of_scope":0,"risks_ask_user":0,"stopped_to_ask_user":false,"plan_deviations":0,"pre_existing_issues":[],"language":"py","visual_check":false,"visual_issues_found":0,"escalated":false,"escalated_from":null,"spiked":false,"spike_resolved":false,"mid_plan_spike":false,"duration_min":null,"notes":"design-smoke"}' "$ts2" "${USER:-unknown}" \
    | PBT_VERCEL_BYPASS="$BYPASS" PBT_DASHBOARD_URL="$DASH" python3 "$POST" 2>&1)
  post_ok=$?
  set -e
  if [ "$post_ok" -eq 0 ]; then
    green "OK live design POST: $out"
  else
    red "FAIL live design POST: $out"
    fail=1
  fi
else
  dim_msg="skip live POST (set PBT_SMOKE_LIVE=1)"
  printf '\033[2m%s\033[0m\n' "$dim_msg"
fi

if [ "$fail" -ne 0 ]; then
  red "SMOKE FAILED"
  exit 1
fi
green "SMOKE PASSED"
