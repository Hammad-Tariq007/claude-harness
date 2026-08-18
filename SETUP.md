# Setup — Autonomous Engineering Harness

## Install into any project

```bash
cd /path/to/your/project

cp -r /path/to/claude-autonomy/.claude   .
cp -r /path/to/claude-autonomy/scripts   .
chmod +x scripts/*.sh scripts/adapters/*.sh scripts/hooks/*.sh

printf '.wt/\n.agent-logs/\n.tickets/\n' >> .gitignore

claude
```

Then, inside Claude:

```
/setup
```

It explores the repo, runs your build and test commands to check they actually work,
asks which ticket system you use, and writes `agent.config.json` and `CLAUDE.md`.
Then it verifies the hooks block correctly and tells you anything you need to fix.

Takes about five minutes. Read the summary it prints — especially the section on what
it could not verify.

Finally, commit the harness (this matters — see "Clean checkout" below):

```bash
git add -f .claude/ scripts/ CLAUDE.md agent.config.json
git commit -m "Add autonomous engineering harness"
git push
```

## Switching ticket system later

```
/ticket-system jira
```

Verifies credentials, checks the label exists, confirms the base branch, updates the
config. Credentials come from your environment:

| System | Needs |
|---|---|
| GitHub | `gh auth login` |
| Jira | `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` |
| Linear | `LINEAR_API_KEY` |

## Clean checkout — the failure that wastes the most time

The harness works in a **fresh git worktree built from the remote branch**. Anything
not committed does not exist there.

If your tests pass locally but the harness parks every ticket, this is almost always
why. Check:

```bash
git status --short          # uncommitted changes the build depends on?
git ls-files | grep -E 'test|requirements-dev|pyproject|tsconfig'
```

Every file your verification commands need must be tracked. `/setup` checks this in
Phase 3, but it is worth knowing about.

## Running tickets

```bash
./scripts/run-ticket.sh 42          # one ticket
./scripts/run-night.sh 2 5          # 2 at a time, 5 total
```

Exit codes: `0` PR opened · `3` parked for a human · other = harness error.

## Scheduling

```bash
crontab -e
```

```
0 22 * * 1-5  cd /path/to/project && ./scripts/run-night.sh 2 5 >> .agent-logs/cron.log 2>&1
```

Weeknights at 22:00. Set `WEBHOOK_URL` to post the morning digest to Slack or
Mattermost.

**Cap the ticket count at your actual morning review capacity.** Ten PRs you skim is
worse than three you read properly — the human review gate is the last real check,
and it only works if you use it.

Note that cron does not inherit your shell environment. Put credentials in the
crontab or source a profile file in the command.

## Parallelism

Each ticket gets its own worktree, so they cannot collide on disk. Start at 1. Move to
2–4 once single-ticket runs are boring. Each run costs roughly $5–8 in tokens and
takes 10–20 minutes wall clock.

The real limit is not the machine — it is how many PRs you will genuinely review
tomorrow morning.

## Per-project files

Only two are project-specific:

- `agent.config.json` — commands, ticket adapter, protected paths
- `CLAUDE.md` — stack, layout, conventions, landmines

Everything else is identical in every repo. `/setup` writes both.

## What to point it at

Good: dependency bumps · flaky test repair · lint and type debt · deprecated API
migration · well-reproduced bug fixes · boilerplate · test coverage gaps.

Bad: novel architecture · ambiguous product decisions · anything touching auth,
payments, or PII. Triage rejects most of these; the protected-path hook catches the rest.

## Honest limitations

- Every reviewer is a Claude model reviewing Claude output, so they share blind spots.
  A cross-provider review pass is the highest-value addition once this is running.
- Holdout tests (`.holdout/` plus `commands.holdout`) are wired but empty. They are
  what catches an agent that satisfies only the tests it can see.
- The harness catches crashes, lint regressions, and test failures. It cannot catch
  wrong behaviour that your test suite does not cover. Your tests are the ceiling.
