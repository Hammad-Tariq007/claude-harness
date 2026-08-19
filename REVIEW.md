# Harness Review — findings and fixes

Full read of all 21 files. Nine defects, each verified against the real file text and
re-tested after patching.

## Critical

**1. Tamper detection had never fired.**
`detect-test-tampering.sh` writes `VIOLATION skip-marker-added`. `run-ticket.sh` grepped
for `SKIP MARKER|ASSERTIONS REMOVED`. The strings never matched, so an agent could have
deleted assertions or added `@pytest.mark.skip` and the run would have opened a PR
normally. Fixed to grep `VIOLATION`; verified end-to-end.

**2. Holdout tests ran in the wrong directory.**
`eval "$HOLDOUT"` had no `cd "$WT"`, so it executed wherever the shell happened to be —
the same class of bug that produced three false parks earlier. Holdout is the check that
catches an agent satisfying only the tests it can see; running it in the wrong tree makes
it meaningless. Fixed.

**3. Parallel runs raced on the baseline cache.**
`run-night.sh` dispatches N tickets at once. All of them computed the baseline for the
same base commit and wrote the same file concurrently. Corrupt cache means every
verification result becomes untrustworthy. Fixed with a `mkdir` lock; late arrivals wait
and reuse.

## High

**4. No ceiling on agent turns.** A looping agent could run to the wall-clock timeout,
which is expensive. Added `--max-turns` (default 250) and a configurable timeout. These
are runaway protection, not workflow limits — a healthy ticket uses far fewer.

**5. Gates ran before the report existed.** The command wrote `REPORT.md` in Phase 6 but
invoked the gates in Phase 4, and the reviewer blocks on a missing report. That burned an
entire remediation round — three model calls — on a sequencing error rather than on code.
Report now comes first.

**6. Remediation re-ran all three gates.** A gate that returned PASS does not need to
re-examine a fix for a different gate's finding. Now only failed gates re-run — roughly
two model calls saved per remediation round, with no loss of coverage.

**7. Digest missed two trust violations.** The morning summary flagged spec modification,
tampering and holdout failure, but not `protected paths were modified` — the most
serious one. Fixed.

## Medium

**8. Baseline artifacts polluted the change detection.** The baseline pass runs `install`
and `build` in the same worktree the agent then uses, so leftover untracked files could
read as agent changes. Now cleaned between the two.

**9. `run-night.sh` git checks depended on the caller's directory.** Fine interactively,
wrong under cron. Pinned to the repo root.

Also removed `escalate_model_on_round` from the config template — it was documented but
never implemented anywhere in the code.

## Model assignment

Only QA moved to Sonnet; it runs commands and compares output, which is mechanical.
Planner, code reviewer and requirements checker stay on Opus, because plan quality
determines everything downstream and the two review gates are where blind spots get
caught. Downgrading those to save money would defeat the purpose of the system.

## A bug I introduced during this review

The baseline lock initially set its own `trap ... EXIT`, which silently replaced the
worktree-cleanup trap — every run would have leaked a worktree. Caught before shipping;
there is now exactly one EXIT handler, asserted by a regression check.

## Verified after patching

All 7 shell scripts pass `bash -n`. Both JSON files parse. 14/14 guard-paths cases
behave correctly (8 blocks, 6 allows). Tamper detection confirmed end-to-end: a skip
marker plus a deleted assertion produce two `VIOLATION` lines that `run-ticket.sh` now
matches.

## Still not fixed, deliberately

- **Every reviewer is a Claude model reviewing Claude output.** They share blind spots.
  A single cross-provider review pass before the PR is the highest-value remaining
  addition.
- **`/setup` cannot write its own config** — the harness self-protection blocks
  `CLAUDE.md` and `agent.config.json`, so setup stages the files and asks a human to copy
  them. Safe, but clumsy.
- **`/setup` overwrites an existing `CLAUDE.md`** rather than merging. On a repo with
  hand-written conventions that is a real loss.
- **No skills.** Language-specific guidance still has to live in `CLAUDE.md`, which loads
  on every turn.
- **macOS untested.** `timeout` and `mapfile` are absent or old on stock macOS.

## The honest ceiling

The harness catches crashes, lint regressions, test failures, protected-path violations
and test tampering. It cannot catch wrong behaviour that your test suite does not cover.
A repo with thin tests gets thin protection, no matter how good the harness is.
