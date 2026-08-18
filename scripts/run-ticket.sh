#!/usr/bin/env bash
#
# run-ticket.sh <ticket-id>
#
# The orchestrator. Everything with an external side effect happens HERE, not in the
# agent: fetching the ticket, freezing the spec, running the real verification,
# committing, and opening the PR. The agent only writes code inside a sandbox worktree.
#
set -euo pipefail

TICKET="${1:?usage: run-ticket.sh <ticket-id>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/agent.config.json"
[ -f "$CONFIG" ] || { echo "FATAL: agent.config.json not found at $ROOT"; exit 1; }

cfg() { jq -r "$1 // empty" "$CONFIG"; }

ADAPTER="$ROOT/scripts/adapters/$(cfg '.tickets.adapter').sh"
BASE="$(cfg '.tickets.base_branch')"; BASE="${BASE:-main}"
BRANCH="agent/$TICKET"
WT="$ROOT/.wt/$TICKET"
LOGDIR="$ROOT/.agent-logs/$TICKET"
mkdir -p "$LOGDIR"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOGDIR/run.log"; }
park() {
  log "PARKED: $*"
  # Preserve the agent's work — a parked ticket often just needs a human nudge,
  # and the cleanup trap would otherwise delete the whole worktree.
  if [ -d "$WT" ]; then
    git -C "$WT" add -A 2>/dev/null || true
    git -C "$WT" -c user.name=agent -c user.email=agent@localhost \
        commit -q -m "[agent][parked] $TICKET" 2>/dev/null || true
    git -C "$WT" diff "origin/$BASE"...HEAD > "$LOGDIR/parked.diff" 2>/dev/null || true
    log "  work preserved: branch $BRANCH + $LOGDIR/parked.diff"
  fi
  echo "$*" > "$LOGDIR/PARKED"
  [ -f "$WT/.tickets/$TICKET/REPORT.md" ] && cp "$WT/.tickets/$TICKET/REPORT.md" "$LOGDIR/" || true
  exit 3
}

# ---------------------------------------------------------------- 1. preflight
for tool in jq git claude; do
  command -v "$tool" >/dev/null || { echo "FATAL: '$tool' not installed"; exit 1; }
done
[ -x "$ADAPTER" ] || { echo "FATAL: adapter not found: $ADAPTER"; exit 1; }

log "=== Ticket $TICKET | adapter=$(cfg '.tickets.adapter') | base=$BASE ==="

# ---------------------------------------------------------------- 2. fetch
log "Fetching ticket..."
"$ADAPTER" fetch "$TICKET" > "$LOGDIR/ticket.md" || park "could not fetch ticket"
[ -s "$LOGDIR/ticket.md" ] || park "ticket body is empty"

# ---------------------------------------------------------------- 3. triage (cheap gate)
log "Triage..."
TRIAGE=$(claude -p "$(cat <<EOF
Classify this ticket. Reply with ONE WORD only, nothing else.

READY        - clear enough for an autonomous agent: has a described problem and an
               implied or stated definition of done.
UNDERSPECIFIED - too vague, missing reproduction steps, or needs a product decision.
SENSITIVE    - touches auth, payments, PII, migrations, infrastructure, CI, or crypto.

--- TICKET ---
$(cat "$LOGDIR/ticket.md")
EOF
)" --model haiku 2>/dev/null | tr -d '[:space:]')

# Claude Code can emit MCP/stderr noise into stdout, so match a keyword rather
# than requiring the whole response to equal one word.
case "$TRIAGE" in
  *UNDERSPECIFIED*) TRIAGE=UNDERSPECIFIED ;;
  *SENSITIVE*)      TRIAGE=SENSITIVE ;;
  *READY*)          TRIAGE=READY ;;
  *)                TRIAGE="UNPARSEABLE:${TRIAGE:0:60}" ;;
esac

log "Triage result: $TRIAGE"
[ "$TRIAGE" = "READY" ] || park "triage returned $TRIAGE — not suitable for autonomous work"

# ---------------------------------------------------------------- 4. isolate
log "Creating worktree..."
git -C "$ROOT" fetch origin "$BASE" --quiet || true
git -C "$ROOT" worktree add --quiet -B "$BRANCH" "$WT" "origin/$BASE" 2>/dev/null \
  || git -C "$ROOT" worktree add --quiet -B "$BRANCH" "$WT" "$BASE"

cleanup() {
  cd "$ROOT"
  git worktree remove --force "$WT" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- 5. freeze the spec
log "Freezing spec..."
mkdir -p "$WT/.tickets/$TICKET"
cp "$LOGDIR/ticket.md" "$WT/.tickets/$TICKET/SPEC.md"
sha256sum "$WT/.tickets/$TICKET/SPEC.md" | awk '{print $1}' > "$LOGDIR/spec.sha256"
chmod 444 "$WT/.tickets/$TICKET/SPEC.md"

# Copy config + agent definitions into the worktree
cp "$CONFIG" "$WT/agent.config.json"
cp -r "$ROOT/.claude" "$WT/.claude"
cp "$ROOT/CLAUDE.md" "$WT/CLAUDE.md" 2>/dev/null || true
mkdir -p "$WT/scripts/hooks" && cp "$ROOT/scripts/hooks/"*.sh "$WT/scripts/hooks/"

# ---------------------------------------------------------------- 6. run the agent
log "Running agent (this is the long part)..."
cd "$WT"
set +e
timeout 3600 claude -p "/execute-ticket $TICKET" \
  --dangerously-skip-permissions \
  --output-format json \
  > "$LOGDIR/agent-output.json" 2> "$LOGDIR/agent-error.log"
AGENT_RC=$?
set -e
log "Agent exited with code $AGENT_RC"
[ $AGENT_RC -eq 124 ] && park "agent timed out after 60 minutes"

# ---------------------------------------------------------------- 7. spec integrity
log "Verifying spec integrity..."
NOW=$(sha256sum "$WT/.tickets/$TICKET/SPEC.md" | awk '{print $1}')
[ "$NOW" = "$(cat "$LOGDIR/spec.sha256")" ] \
  || park "SPEC WAS MODIFIED — treat as a trust violation, do not merge"

# ---------------------------------------------------------------- 8. tamper log
if [ -s "$WT/.tickets/tamper.log" ]; then
  cp "$WT/.tickets/tamper.log" "$LOGDIR/"
  log "WARNING: tamper log is non-empty:"
  cat "$WT/.tickets/tamper.log" | tee -a "$LOGDIR/run.log"
  grep -q "SKIP MARKER\|ASSERTIONS REMOVED" "$WT/.tickets/tamper.log" \
    && park "test tampering detected — do not merge"
fi

# ---------------------------------------------------------------- 9. INDEPENDENT verification
# This is the critical step: WE run the tests, not the agent. Its self-report is not evidence.
log "Running independent verification..."
VERIFY_OK=1
for step in install test lint typecheck build; do
  CMD=$(cfg ".commands.$step")
  [ -z "$CMD" ] && continue
  log "  → $step: $CMD"
  if ! ( cd "$WT" && eval "$CMD" ) > "$LOGDIR/verify-$step.log" 2>&1; then
    log "  ✗ $step FAILED (see verify-$step.log)"
    [ "$step" = "install" ] && park "install failed — environment problem, not agent's fault"
    VERIFY_OK=0
  else
    log "  ✓ $step passed"
  fi
done
[ $VERIFY_OK -eq 1 ] || park "independent verification failed"

# --------------------------------------------------------------- 10. holdout tests
HOLDOUT=$(cfg '.commands.holdout')
if [ -n "$HOLDOUT" ] && [ -d "$ROOT/.holdout" ]; then
  log "Running holdout tests (agent never saw these)..."
  cp -r "$ROOT/.holdout" "$WT/.holdout"
  if ! eval "$HOLDOUT" > "$LOGDIR/verify-holdout.log" 2>&1; then
    park "HOLDOUT FAILED while visible tests passed — classic test-gaming signature, do not merge"
  fi
  log "  ✓ holdout passed"
  rm -rf "$WT/.holdout"
fi

# --------------------------------------------------------------- 11. sanity checks
[ -f "$WT/.tickets/$TICKET/REPORT.md" ] || park "agent produced no REPORT.md"
if ! git -C "$WT" diff --quiet "origin/$BASE" -- 2>/dev/null; then :; else
  git -C "$WT" diff --quiet HEAD 2>/dev/null && park "agent made no changes"
fi

# --------------------------------------------------------------- 12. commit + PR
log "Committing and opening PR..."
cd "$WT"
# Restore harness files to their committed state. They are tracked in git now,
# so deleting them would show up as a deletion in the PR diff.
git checkout -- .claude scripts/hooks agent.config.json CLAUDE.md 2>/dev/null || true
git clean -fd .claude scripts/hooks 2>/dev/null || true
git add -A
git -c user.name="agent" -c user.email="agent@localhost" \
    commit -q -m "[agent] $TICKET

$(head -3 "$LOGDIR/ticket.md")

Verified: $(cfg '.commands.test') / $(cfg '.commands.lint')
Report: .tickets/$TICKET/REPORT.md"

git push -q origin "$BRANCH" --force-with-lease
"$ADAPTER" open_pr "$TICKET" "$BRANCH" "$WT/.tickets/$TICKET/REPORT.md" "$BASE" \
  | tee "$LOGDIR/pr-url.txt"

# Post back to the ticket system
"$ADAPTER" comment "$TICKET" "$WT/.tickets/$TICKET/REPORT.md" 2>/dev/null || true

log "✅ $TICKET → PR opened. Human review required before merge."
