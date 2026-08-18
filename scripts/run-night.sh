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
  echo "Dispatched: ${#TICKETS[@]} · Parallelism: $PARALLEL"
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
    if grep -qi "SPEC WAS MODIFIED\|test tampering\|HOLDOUT FAILED" "$ROOT/.agent-logs/$t/PARKED" 2>/dev/null; then
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
