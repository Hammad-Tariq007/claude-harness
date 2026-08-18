#!/usr/bin/env bash
# PostToolUse hook — logs test-gaming patterns. run-ticket.sh parks on VIOLATION.
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[ -z "$FILE" ] && exit 0

LOG="$ROOT/.tickets/tamper.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
TS=$(date -u +%FT%TZ)

case "$FILE" in
  /*) REL="${FILE#"$ROOT"/}" ;;
   *) REL="$FILE" ;;
esac

DIFF=$(git -C "$ROOT" diff -U0 -- "$REL" 2>/dev/null || true)

case "$REL" in
  *test*|*spec*|*Test.php|*_test.go|*.test.*|*.spec.*)
    echo "[$TS] INFO test-file-modified: $REL" >> "$LOG" ;;
esac

if printf '%s' "$DIFF" | grep -qE '^\+.*(\.skip\(|\.only\(|@pytest\.mark\.skip|xit\(|xdescribe\(|t\.Skip\(|markTestSkipped|@Ignore)'; then
  echo "[$TS] VIOLATION skip-marker-added: $REL" >> "$LOG"
  echo "WARNING: you added a test skip/disable marker in $REL. Revert it or stop and report." >&2
fi

DEL=$(printf '%s' "$DIFF" | grep -cE '^-.*(assert|expect\(|should\.|\.toBe|\.toEqual)' || true)
if [ "${DEL:-0}" -gt 0 ]; then
  echo "[$TS] VIOLATION assertions-removed ($DEL): $REL" >> "$LOG"
  echo "WARNING: $DEL assertion line(s) removed from $REL. Justify in REPORT.md or revert." >&2
fi

case "$REL" in
  *test*|*spec*) ;;
  *)
    if printf '%s' "$DIFF" | grep -qiE '^\+.*(if.*(is_test|isTest|TESTING|PYTEST_CURRENT_TEST|NODE_ENV.*test))'; then
      echo "[$TS] VIOLATION test-only-branch: $REL" >> "$LOG"
      echo "WARNING: production code in $REL now branches on a test-only condition." >&2
    fi ;;
esac

exit 0
