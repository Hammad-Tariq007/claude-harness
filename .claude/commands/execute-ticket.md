---
description: Execute a ticket end-to-end with planning, QA, review and requirements gates
argument-hint: <ticket-id>
---

Ticket: **$1**

The wrapper script has already fetched the ticket, created the worktree, and frozen the
spec at `.tickets/$1/SPEC.md` (read-only). Do not attempt to create or modify it.

Follow these phases in order. Do not skip ahead. Do not stop early on success —
run every gate.

---

### Phase 1 — Plan

Invoke the `planner` subagent for ticket $1. Save its output to `.tickets/$1/PLAN.md`.

If `PLAN.md` begins with **BLOCKED**: write `.tickets/$1/REPORT.md` explaining the blocker,
then **stop immediately**. Do not implement anything.

### Phase 2 — Implement

You are the sole writer. Follow `PLAN.md`. Constraints:
- Stay inside the change surface declared in `PLAN.md`. If you must go outside it, append
  the reason to `PLAN.md` under "Scope changes" first.
- Make the minimal change. No unrelated refactors or reformatting.
- Read `agent.config.json` → `commands` and run `install` first if it is non-empty.

### Phase 3 — Self-test

Run every non-empty command from `agent.config.json` → `commands`.
Fix genuine failures. You may iterate here up to **3 times**.

Forbidden while fixing, without exception: weakening a test, deleting a test case,
adding a skip marker, hard-coding values to match test inputs, or branching on
test-only conditions. If a test seems wrong, note it in `REPORT.md` and leave it alone.

### Phase 4 — Gates (run all three, in parallel, in a single message)

Invoke `qa-tester`, `code-reviewer`, and `requirements-checker` together.
They are read-only and independent — launching them concurrently is intentional.

Write each verdict to `.tickets/$1/gates-round-N.md`.

### Phase 5 — Remediation

If any gate fails:
- Fix only what the gates flagged. Do not opportunistically change other things.
- Re-run Phase 3, then Phase 4.
- **Maximum 2 remediation rounds** (`policy.max_fix_rounds` in `agent.config.json`).

If gates still fail after round 2: write `REPORT.md` describing the unresolved findings
honestly, and **stop**. Do not loop further. A parked ticket is an acceptable outcome.

### Phase 6 — Report

Write `.tickets/$1/REPORT.md`:

```markdown
# Ticket $1 — <title>

## Status
COMPLETE | PARTIAL | BLOCKED

## What changed
<files and a one-line reason each>

## Acceptance criteria
| # | Criterion | Status | Evidence |

## Verification
| Command | Result |
Gate verdicts: QA <x> · Review <y> · Requirements <z>

## NOT done
<be specific and honest — this section is the most valuable one>

## Assumptions made

## Needs a human decision

## New dependencies added
```

Then stop. **Do not commit, do not push, do not open a PR.**
The wrapper script does all of that after running its own independent verification.
