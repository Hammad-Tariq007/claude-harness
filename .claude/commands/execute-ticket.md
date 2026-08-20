---
description: Execute a ticket end-to-end with planning, QA, review and requirements gates
argument-hint: <ticket-id>
---

Ticket: **$1**

The wrapper script has already fetched the ticket, created the worktree, and frozen the
spec at `.tickets/$1/SPEC.md` (read-only). Do not attempt to create or modify it.

Follow these phases in order. Do not skip ahead.

**Efficiency matters.** Each gate is a separate model invocation with real cost. Do not
re-run a gate that already passed, and do not re-run gates on a change they cannot see.

---

### Never block on a process or a timer

You are running headless with no terminal. Do not poll for a process, do not `sleep`
to wait for something, and do not run any command that waits on external state.

In particular, never wait on the process that launched you — a `while kill -0 <pid>`
loop against your own parent deadlocks permanently, because that process cannot exit
until you do.

Subagents return their results to you directly. There is nothing to poll for.

### Phase 1 — Plan

Invoke the `planner` subagent for ticket $1. Save its output to `.tickets/$1/PLAN.md`.

If `PLAN.md` begins with **BLOCKED**: write `.tickets/$1/REPORT.md` explaining the
blocker, then **stop immediately**. Do not implement anything. A parked ticket costs
one planner call; a wrongly-implemented one costs a human's afternoon.

### Phase 2 — Implement

You are the sole writer. Follow `PLAN.md`. Constraints:
- Stay inside the change surface declared in `PLAN.md`. If you must go outside it,
  append the reason to `PLAN.md` under "Scope changes" first.
- Make the minimal change. No unrelated refactors, no drive-by formatting.
- Read `agent.config.json` → `commands` and run `install` first if it is non-empty.

### Phase 3 — Self-test

Run every non-empty command from `agent.config.json` → `commands`.
Fix genuine failures. Iterate here up to **3 times**, then move on regardless — the
gates and the wrapper will catch what remains. Looping here is the most expensive
way to fail.

Forbidden while fixing, without exception: weakening a test, deleting a test case,
adding a skip marker, hard-coding values to match test inputs, or branching on
test-only conditions. If a test seems genuinely wrong, note it in `REPORT.md` and
leave it alone.

### Phase 4 — Write the report FIRST

Write `.tickets/$1/REPORT.md` **before** invoking any gate. The gates check for its
existence; without it they block on a missing artefact rather than on your code, and
that wastes an entire remediation round on nothing.

```markdown
# Ticket $1 — <title>

## Status
COMPLETE | PARTIAL | BLOCKED

## What changed
<files and a one-line reason each>

## Acceptance criteria
| # | Criterion | Status | Evidence (file:line) |

## Verification
| Command | Result |

## NOT done
<be specific and honest — this section is the most valuable one>

## Assumptions made

## Needs a human decision

## New dependencies added
```

### Phase 5 — Gates (all three, in parallel, in a single message)

Invoke `qa-tester`, `code-reviewer`, and `requirements-checker` **together in one
message**. They are read-only and independent; running them sequentially triples the
wall-clock time for no benefit.

Record the verdicts in `.tickets/$1/gates-round-1.md`.

### Phase 6 — Remediation

If every gate passes, skip this phase entirely.

Otherwise:
- Fix **only** what the gates flagged. Do not opportunistically change other things.
- Re-run Phase 3's commands.
- **Re-run only the gates that failed.** A gate that returned PASS does not need to
  see the fix for a different gate's finding. Re-running all three costs three model
  invocations to re-confirm two results you already have.
- Update `REPORT.md` to reflect the fixes, and record the new verdicts in
  `gates-round-2.md`.

**Maximum rounds: `policy.max_fix_rounds` in `agent.config.json`** (default 2).

If gates still fail after the last round: update `REPORT.md` with the unresolved
findings, honestly and specifically, and **stop**. Do not loop further. A parked
ticket with an accurate report is a good outcome.

### Phase 7 — Stop

Confirm `REPORT.md` reflects the final state, then stop.

**Do not commit, do not push, do not open a PR.** The wrapper script does all of that
after running its own independent verification. Anything you commit yourself bypasses
the check that exists specifically to catch you being wrong.
