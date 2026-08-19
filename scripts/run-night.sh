#!/usr/bin/env bash
#
# run-night.sh [max-parallel] [max-tickets]
#
# Picks up every ticket labelled agent-ready, runs them in parallel (one writer each,
# separate worktrees), and writes a morning digest.
#
# Cron example (weeknights at 22:00):
#   0 22 * * 1-5  cd /srv/myrepo && ./scripts/run-night.sh 4 10 >> .agent-logs/cron.log 2>&1
#
set -euo pipefail

PARALLEL="${1:-4}"
MAX="${2:-8}"          # keep this at or below your morning review capacity
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/agent.config.json"
cfg() { jq -r "$1 // empty" "$CONFIG"; }

ADAPTER="$ROOT/scripts/adapters/$(cfg '.tickets.adapter').sh"
LABEL="$(cfg '.tickets.ready_label')"; LABEL="${LABEL:-agent-ready}"
STAMP=$(date -u +%Y%m%d-%H%M)
DIGEST="$ROOT/.agent-logs/digest-$STAMP.md"
mkdir -p "$ROOT/.agent-logs"

# ------------------------------------------------------------------ preflight
# Fail fast. A batch started against a broken environment parks every ticket in it.
echo "Preflight..."
PREFLIGHT_FAIL=0

for tool in claude git jq; do
  command -v "$tool" >/dev/null || { echo "  ✗ $tool not found"; PREFLIGHT_FAIL=1; }
done

# Docker, only if any configured command mentions it.
if jq -r '.commands | to_entries[].value' "$CONFIG" 2>/dev/null | grep -q docker; then
  if docker info >/dev/null 2>&1; then
    echo "  ✓ docker daemon reachable"
  else
    echo "  ✗ docker daemon unreachable — every ticket would park"
    PREFLIGHT_FAIL=1
  fi
fi

# Ticket adapter credentials.
if "$ADAPTER" list_ready "$LABEL" >/dev/null 2>&1; then
  echo "  ✓ ticket adapter authenticated"
else
  echo "  ✗ ticket adapter failed — check credentials"
  PREFLIGHT_FAIL=1
fi

# Remote reachable (the runner pushes branches).
if git -C "$ROOT" ls-remote --exit-code origin >/dev/null 2>&1; then
  echo "  ✓ git remote reachable"
else
  echo "  ✗ git remote unreachable"
  PREFLIGHT_FAIL=1
fi

# Uncommitted work would not exist in the fresh worktree.
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  echo "  ⚠ uncommitted changes — these will NOT be present in agent worktrees"
fi

if [ "$PREFLIGHT_FAIL" = "1" ]; then
  echo
  echo "Preflight failed. Not starting the batch — fix the above and re-run."
  exit 1
fi
echo "  Preflight OK"
echo

echo "Fetching tickets labelled '$LABEL'..."
mapfile -t TICKETS < <("$ADAPTER" list_ready "$LABEL" | head -n "$MAX")
[ ${#TICKETS[@]} -eq 0 ] && { echo "No ready tickets. Nothing to do."; exit 0; }

echo "Dispatching ${#TICKETS[@]} tickets, $PARALLEL at a time."
printf '%s\n' "${TICKETS[@]}" \
  | xargs -P "$PARALLEL" -I{} bash -c \
      '"'"$ROOT"'/scripts/run-ticket.sh" "$@" || true' _ {}

# ------------------------------------------------------------------ digest
{
  echo "# Overnight run — $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo
  READY=0; PARKED=0
  for t in "${TICKETS[@]}"; do
    [ -f "$ROOT/.agent-logs/$t/pr-url.txt" ] && READY=$((READY+1))
    [ -f "$ROOT/.agent-logs/$t/PARKED" ]     && PARKED=$((PARKED+1))
  done
  echo "Dispatched: ${#TICKETS[@]} · PRs: $READY · Parked: $PARKED · Parallelism: $PARALLEL"
  echo
  echo "## Ready for review"
  for t in "${TICKETS[@]}"; do
    if [ -f "$ROOT/.agent-logs/$t/pr-url.txt" ]; then
      echo "- **$t** — $(cat "$ROOT/.agent-logs/$t/pr-url.txt")"
    fi
  done
  echo
  echo "## Parked (need a human)"
  for t in "${TICKETS[@]}"; do
    if [ -f "$ROOT/.agent-logs/$t/PARKED" ]; then
      echo "- **$t** — $(cat "$ROOT/.agent-logs/$t/PARKED")"
    fi
  done
  echo
  echo "## Trust flags"
  FLAGS=0
  for t in "${TICKETS[@]}"; do
    if [ -s "$ROOT/.agent-logs/$t/tamper.log" ]; then
      echo "- ⚠️ **$t** — tamper log non-empty, inspect before merging"; FLAGS=1
    fi
    if grep -qi "SPEC WAS MODIFIED\|test tampering\|HOLDOUT FAILED\|protected paths were modified" "$ROOT/.agent-logs/$t/PARKED" 2>/dev/null; then
      echo "- 🚨 **$t** — trust violation, do NOT merge"; FLAGS=1
    fi
  done
  [ $FLAGS -eq 0 ] && echo "None. ✅"
  echo
  echo "_Review PRs before merging. Nothing here has been merged automatically._"
} > "$DIGEST"

cat "$DIGEST"

# Optional: post to Slack / Mattermost
if [ -n "${WEBHOOK_URL:-}" ]; then
  jq -Rs '{text: .}' < "$DIGEST" \
    | curl -sS -X POST -H 'Content-Type: application/json' -d @- "$WEBHOOK_URL" > /dev/null
  echo "Digest posted to webhook."
fi
