#!/bin/bash
#
# PBT log mirror — feeds the weekly Claude Cowork audit.
#
# The Cowork audit VM reads /mnt/PBT/.pbt-log.jsonl, which maps to ~/PBT/ on
# the Mac. This script mirrors the canonical append-only log into that folder
# so the audit always sees current data. Invoked every 15 minutes (and at
# login) by the com.nv.pbt-sync LaunchAgent. Atomic and idempotent.

set -uo pipefail

SRC="$HOME/.pbt-log.jsonl"
DEST_DIR="$HOME/PBT"
DEST="$DEST_DIR/.pbt-log.jsonl"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Nothing to mirror yet — not an error, just exit quietly.
[ -s "$SRC" ] || { echo "$(stamp) sync: source missing/empty, skip"; exit 0; }

mkdir -p "$DEST_DIR" || { echo "$(stamp) sync: cannot create $DEST_DIR"; exit 1; }

# Atomic swap: write a temp copy on the same filesystem, then rename over the
# destination so the audit never observes a half-written file.
TMP="$DEST.tmp.$$"
if cp "$SRC" "$TMP" && mv -f "$TMP" "$DEST"; then
  echo "$(stamp) sync: mirrored $(wc -l < "$DEST" | tr -d ' ') lines -> $DEST"
  exit 0
fi

rm -f "$TMP" 2>/dev/null
echo "$(stamp) sync: mirror failed"
exit 1
