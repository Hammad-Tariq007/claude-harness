# Runbook

For whoever is on point when an overnight batch has run.

## Reading the morning digest

`.agent-logs/digest-*.md` lists three things: PRs ready, tickets parked, trust flags.
Read trust flags first — they mean do not merge, not merge carefully.

## Exit codes

| Code | Meaning | Action |
|---|---|---|
| 0 | PR opened | Review the diff, then merge |
| 3 | Parked | Read `.agent-logs/<id>/PARKED` for the reason |
| other | Harness error | Read `.agent-logs/<id>/run.log` |

## Park reasons and what to do

| Reason | Cause | Action |
|---|---|---|
| `triage returned UNDERSPECIFIED` | Ticket too vague | Rewrite the ticket with acceptance criteria |
| `triage returned SENSITIVE` | Auth, payments, PII, migrations, CI | Assign to a human. Do not override |
| `triage returned INFEASIBLE` | Repo lacks a required dependency | Add it by hand, or close the ticket |
| `install failed` | Environment, not the agent | Check Docker, network, credentials |
| `independent verification failed` | Real regression | Read `verify-*.log`; the diff is on branch `agent/<id>` |
| `agent made no changes` | Agent produced nothing | Read `agent-error.log` — usually a turn cap or a blocked tool |
| `agent timed out` | Exceeded `policy.timeout_seconds` | Raise it, or split the ticket |
| **`SPEC WAS MODIFIED`** | Agent edited its own requirements | **Do not merge. Investigate** |
| **`protected paths were modified`** | Agent touched a protected file | **Do not merge. Investigate** |
| **`test tampering detected`** | Skip marker or deleted assertion | **Do not merge. Read `tamper.log`** |
| **`HOLDOUT FAILED`** | Passed visible tests, failed hidden ones | **Do not merge. This is the test-gaming signature** |

The four bold rows are trust violations. Treat them as you would a colleague quietly
disabling CI: the code may be fine, but something in the setup needs understanding
before anything merges.

## Reviewing an agent PR

Read in this order:

1. **The file list.** Anything outside the expected surface is a finding.
2. **The diff.** The report describes intent; the diff is fact. When they disagree,
   the diff wins.
3. **The "NOT done" section of the PR body.** This is the highest-value part —
   it is where assumptions and deferred edge cases are disclosed.
4. **Test changes.** Weakened assertions and removed cases are the thing to look for.
   Deleting tests for behaviour the ticket removed is legitimate; loosening a test on
   surviving behaviour is not.

## Reverting a merged agent PR

```bash
gh pr view <n> --json mergeCommit --jq .mergeCommit.oid
git revert -m 1 <sha> && git push
```

Then reopen the ticket with what went wrong. That text is the most useful input the
next run can have.

## Rerunning a parked ticket

The work is preserved on branch `agent/<id>` and in `.agent-logs/<id>/parked.diff`.
Fix the cause, then re-run. The run starts fresh from the frozen spec; it does not
resume.

```bash
git worktree remove --force .wt/<id> 2>/dev/null
git branch -D agent/<id> 2>/dev/null
ticket <id>
```

## Before an overnight batch

```bash
git status --short        # uncommitted work will NOT exist in agent worktrees
git push                  # worktrees are built from origin/<base>
docker info               # only if any configured command needs it
tickets                   # confirm the queue is what you expect
```

Cap the batch at your real morning review capacity. Ten PRs skimmed is worse than
three read properly — the human merge gate is the last real check, and it only works
if it is used.

## Cost

Roughly $2–3 per ticket at current model assignment, most of it Opus in the planner
and the two review gates. A parked ticket costs pennies if it parks at triage, and
close to a full run if it parks at verification.

## Escalation

Anything the harness itself does wrong — false parks, hooks blocking legitimate
commands, PRs containing harness files — is a harness bug, not an agent bug. Record
the `.agent-logs/<id>/` directory and raise it; do not work around it locally, or the
fix never reaches anyone else.
