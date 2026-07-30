#!/usr/bin/env bash
# Package the Claude Design PBT skill as a ZIP for Customize > Skills upload.
# Layout: ZIP root = plan-build-test-design/ (SKILL.md + scripts/).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/claude-design/plan-build-test-design"
OUT_DIR="${ROOT}/dist"
OUT_ZIP="${OUT_DIR}/plan-build-test-design.zip"

if [ ! -f "${SRC}/SKILL.md" ]; then
  echo "missing ${SRC}/SKILL.md" >&2
  exit 1
fi
if [ ! -f "${SRC}/scripts/pbt_post.py" ]; then
  echo "missing ${SRC}/scripts/pbt_post.py" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_ZIP"

# Skill folder must be the ZIP root entry (not nested under claude-design/).
(
  cd "${ROOT}/claude-design"
  zip -r "$OUT_ZIP" plan-build-test-design \
    -x '*.DS_Store' -x '*/__pycache__/*' -x '*.pyc'
)

echo "Wrote ${OUT_ZIP}"
unzip -l "$OUT_ZIP" | head -20
