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
    git -C "$WT" -c user.name=agent -c user.email=agent@localhost -c commit.gpgsign=false \
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
               Judge the ticket text only. A hard task with clear criteria is READY.
SENSITIVE    - touches auth, payments, PII, migrations, infrastructure, CI, or crypto.
INFEASIBLE   - clear and well-specified, but this repo cannot support it: it needs a
               framework, build tool, or dependency that is absent, and adding it would
               require editing a protected path. Judge against the repo, not the ticket.

--- TICKET ---
$(cat "$LOGDIR/ticket.md")
EOF
)" --model haiku 2>/dev/null | tr -d '[:space:]')

# Claude Code can emit MCP/stderr noise into stdout, so match a keyword rather
# than requiring the whole response to equal one word.
case "$TRIAGE" in
  *UNDERSPECIFIED*) TRIAGE=UNDERSPECIFIED ;;
  *INFEASIBLE*)     TRIAGE=INFEASIBLE ;;
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

BASELINE_LOCK=""
cleanup() {
  cd "$ROOT"
  [ -n "$BASELINE_LOCK" ] && rmdir "$BASELINE_LOCK" 2>/dev/null || true
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
rm -rf "$WT/.claude" && cp -r "$ROOT/.claude" "$WT/.claude"
cp "$ROOT/CLAUDE.md" "$WT/CLAUDE.md" 2>/dev/null || true
mkdir -p "$WT/scripts/hooks" && cp "$ROOT/scripts/hooks/"*.sh "$WT/scripts/hooks/"

# ------------------------------------------------------- 5b. baseline verification
# Establish which gates already fail on untouched code. Without this the harness
# blames the agent for pre-existing debt and for flaky infrastructure.
# Cached per base commit, so it costs nothing on repeat runs.
BASE_SHA=$(git -C "$WT" rev-parse HEAD)
BASELINE_CACHE="$ROOT/.agent-logs/baseline-$BASE_SHA.txt"

# run-night.sh dispatches tickets in parallel; without a lock they race here and
# corrupt the cache. First one computes it, the rest wait and reuse.
# Released by cleanup() — do NOT set a second EXIT trap, it would clobber it.
if mkdir "$BASELINE_CACHE.lock" 2>/dev/null; then
  BASELINE_LOCK="$BASELINE_CACHE.lock"
else
  BASELINE_LOCK=""
  log "Baseline: another ticket is computing it, waiting..."
  for _ in $(seq 1 120); do [ -d "$BASELINE_CACHE.lock" ] || break; sleep 5; done
fi

if [ -f "$BASELINE_CACHE" ]; then
  log "Baseline: cached for $BASE_SHA"
else
  log "Baseline: verifying untouched code (one-off for this commit)..."
  : > "$BASELINE_CACHE"
  for step in install test lint typecheck build; do
    CMD=$(cfg ".commands.$step")
    [ -z "$CMD" ] && continue
    if ( cd "$WT" && eval "$CMD" ) > "$LOGDIR/baseline-$step.log" 2>&1; then
      echo "$step=pass" >> "$BASELINE_CACHE"
      log "  baseline $step: pass"
    else
      echo "$step=fail" >> "$BASELINE_CACHE"
      log "  baseline $step: FAIL (pre-existing — the agent will not be blamed for this)"
    fi
  done
fi

baseline_status() { grep "^$1=" "$BASELINE_CACHE" 2>/dev/null | cut -d= -f2; }

# Baseline ran install/build in this worktree. Drop any untracked artifacts it left,
# so step 7b does not read them as changes the agent made.
git -C "$WT" clean -fdq -e node_modules -e .venv -e vendor 2>/dev/null || true

# ---------------------------------------------------------------- 6. run the agent
log "Running agent (this is the long part)..."
cd "$WT"
set +e
MAX_TURNS=$(cfg '.policy.max_turns'); MAX_TURNS="${MAX_TURNS:-250}"
TIMEOUT_S=$(cfg '.policy.timeout_seconds'); TIMEOUT_S="${TIMEOUT_S:-5400}"
log "  caps: ${MAX_TURNS} turns, ${TIMEOUT_S}s wall clock"
timeout "$TIMEOUT_S" claude -p "/execute-ticket $TICKET" \
  --max-turns "$MAX_TURNS" \
  --dangerously-skip-permissions \
  --output-format json \
  > "$LOGDIR/agent-output.json" 2> "$LOGDIR/agent-error.log"
AGENT_RC=$?
set -e
log "Agent exited with code $AGENT_RC"
[ $AGENT_RC -eq 124 ] && park "agent timed out after ${TIMEOUT_S}s (raise policy.timeout_seconds if legitimate)"

# ---------------------------------------------------------------- 7. spec integrity
log "Verifying spec integrity..."
NOW=$(sha256sum "$WT/.tickets/$TICKET/SPEC.md" | awk '{print $1}')
[ "$NOW" = "$(cat "$LOGDIR/spec.sha256")" ] \
  || park "SPEC WAS MODIFIED — treat as a trust violation, do not merge"

# ------------------------------------------------- 7b. protected paths untouched
# Definitive check. The PreToolUse hook pattern-matches commands and can be evaded
# by a sufficiently creative shell invocation; this inspects what actually changed.
log "Checking protected paths..."
CHANGED=$(git -C "$WT" diff --name-only "origin/$BASE"...HEAD 2>/dev/null; \
          git -C "$WT" diff --name-only 2>/dev/null; \
          git -C "$WT" ls-files --others --exclude-standard 2>/dev/null)
CHANGED=$(printf '%s\n' "$CHANGED" | sort -u | grep -v '^$' || true)

VIOLATIONS=""
while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # shellcheck disable=SC2254
    case "$f" in
      $pat) VIOLATIONS="$VIOLATIONS$f (matches $pat)\n" ;;
    esac
  done <<< "$CHANGED"
done < <(jq -r '.policy.protected_paths[]?' "$CONFIG" 2>/dev/null)

# The harness itself is never editable by the agent.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    .claude/*|scripts/*|.tickets/*/SPEC.md)
      VIOLATIONS="$VIOLATIONS$f (harness file)\n" ;;
    CLAUDE.md|agent.config.json)
      # These are legitimately written by /setup, but never during a ticket —
      # and a ticket is exactly what this script is running.
      VIOLATIONS="$VIOLATIONS$f (harness file)\n" ;;
  esac
done <<< "$CHANGED"

if [ -n "$VIOLATIONS" ]; then
  printf 'Protected paths modified:\n%b' "$VIOLATIONS" | tee -a "$LOGDIR/run.log"
  park "protected paths were modified — trust violation, do not merge"
fi
log "  ✓ no protected paths touched"

# ---------------------------------------------------------------- 8. tamper log
if [ -s "$WT/.tickets/tamper.log" ]; then
  cp "$WT/.tickets/tamper.log" "$LOGDIR/"
  log "WARNING: tamper log is non-empty:"
  cat "$WT/.tickets/tamper.log" | tee -a "$LOGDIR/run.log"
  grep -q "VIOLATION" "$WT/.tickets/tamper.log" \
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
  if ( cd "$WT" && eval "$CMD" ) > "$LOGDIR/verify-$step.log" 2>&1; then
    log "  ✓ $step passed"
    continue
  fi

  # One retry. Absorbs flaky services, container cold starts, network blips.
  log "  … $step failed, retrying once in 10s"
  sleep 10
  if ( cd "$WT" && eval "$CMD" ) > "$LOGDIR/verify-$step.log" 2>&1; then
    log "  ✓ $step passed on retry (transient)"
    continue
  fi

  # Still failing. Was it already failing before the agent touched anything?
  if [ "$(baseline_status "$step")" = "fail" ]; then
    log "  ⚠ $step fails, but it ALSO failed on untouched code — pre-existing, not a regression"
    echo "$step: pre-existing failure" >> "$LOGDIR/pre-existing.txt"
    continue
  fi

  log "  ✗ $step REGRESSED (passed on baseline, fails now — see verify-$step.log)"
  [ "$step" = "install" ] && park "install failed — environment problem, not agent's fault"
  VERIFY_OK=0
done
[ $VERIFY_OK -eq 1 ] || park "independent verification failed — $(cat "$LOGDIR"/verify-*.log 2>/dev/null | tail -3 | tr '\n' ' ')"

# --------------------------------------------------------------- 10. holdout tests
HOLDOUT=$(cfg '.commands.holdout')
if [ -n "$HOLDOUT" ] && [ -d "$ROOT/.holdout" ]; then
  log "Running holdout tests (agent never saw these)..."
  cp -r "$ROOT/.holdout" "$WT/.holdout"
  if ! ( cd "$WT" && eval "$HOLDOUT" ) > "$LOGDIR/verify-holdout.log" 2>&1; then
    park "HOLDOUT FAILED while visible tests passed — classic test-gaming signature, do not merge"
  fi
  log "  ✓ holdout passed"
  rm -rf "$WT/.holdout"
fi

# --------------------------------------------------------------- 11. sanity checks
[ -f "$WT/.tickets/$TICKET/REPORT.md" ] || park "agent produced no REPORT.md"
# Count modified AND untracked files. `git diff` ignores untracked entirely, so a
# ticket that only adds new files looked like the agent had done nothing at all.
CHANGE_COUNT=$( { git -C "$WT" diff --name-only 2>/dev/null
                  git -C "$WT" diff --name-only --cached 2>/dev/null
                  git -C "$WT" ls-files --others --exclude-standard 2>/dev/null
                } | sort -u | grep -v '^$' | grep -v '^\.tickets/' | wc -l )
[ "$CHANGE_COUNT" -eq 0 ] && park "agent made no changes"
log "  $CHANGE_COUNT file(s) changed"

# --------------------------------------------------------------- 12. commit + PR
log "Committing and opening PR..."
cd "$WT"
# Restore harness files to their committed state. They are tracked in git now,
# so deleting them would show up as a deletion in the PR diff.
git checkout -- .claude scripts/hooks agent.config.json CLAUDE.md 2>/dev/null || true
git clean -fd .claude scripts/hooks 2>/dev/null || true
git add -A
# Identity is configurable. Signing is force-disabled: an autonomous run has no
# TTY, so pinentry times out and the commit fails outright.
AUTHOR_NAME=$(cfg '.git.author_name');   AUTHOR_NAME="${AUTHOR_NAME:-agent}"
AUTHOR_EMAIL=$(cfg '.git.author_email'); AUTHOR_EMAIL="${AUTHOR_EMAIL:-agent@localhost}"
git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" -c commit.gpgsign=false \
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
