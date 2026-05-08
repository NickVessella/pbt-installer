#!/bin/bash
#
# PBT Log Backup
#
# Creates a timestamped snapshot of ~/.pbt-log.jsonl before any audit or
# destructive operation. Keeps the last 30 backups and prunes older ones.
#
# Usage:
#   bash backup-log.sh
#   bash backup-log.sh /path/to/other.jsonl   # backup a specific log file
#
# Called automatically as step 1 of any Cowork audit task. Can also be run
# manually at any time — it is idempotent and non-destructive.

set -euo pipefail

LOG_FILE="${1:-$HOME/.pbt-log.jsonl}"
BACKUP_DIR="$HOME/.pbt-log-backups"
MAX_BACKUPS=30

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

if [ ! -f "$LOG_FILE" ]; then
  red "Log file not found: $LOG_FILE"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/pbt-log_${TIMESTAMP}.jsonl"

cp "$LOG_FILE" "$BACKUP_FILE"

LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
FILE_SIZE=$(du -sh "$LOG_FILE" | cut -f1)

green "✓ Backup created → $BACKUP_FILE"
dim  "  Source: $LOG_FILE ($LINE_COUNT lines, $FILE_SIZE)"

# Prune oldest backups beyond MAX_BACKUPS
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/pbt-log_*.jsonl 2>/dev/null | wc -l | tr -d ' ')

if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
  EXCESS=$(( BACKUP_COUNT - MAX_BACKUPS ))
  ls -1t "$BACKUP_DIR"/pbt-log_*.jsonl | tail -"$EXCESS" | xargs rm
  dim "  pruned $EXCESS oldest backup(s) — kept $MAX_BACKUPS most recent"
  BACKUP_COUNT=$MAX_BACKUPS
fi

green "✓ Done — $BACKUP_COUNT backup(s) in $BACKUP_DIR"
