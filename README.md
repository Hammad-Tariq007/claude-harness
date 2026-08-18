# Claude Harness

Autonomous engineering harness. Give it a ticket number; it plans, implements,
self-tests, gets graded by three independent reviewers, and opens a pull request.
A human always merges.

## Install into a project

```bash
cd /path/to/your/project
cp -r ~/claude-harness/.claude ~/claude-harness/scripts .
chmod +x scripts/*.sh scripts/adapters/*.sh scripts/hooks/*.sh
printf '.wt/\n.agent-logs/\n.tickets/\n' >> .gitignore

claude
```

Then run `/setup` inside Claude. It explores the repo, verifies your build and test
commands actually work, asks which ticket system you use, and writes
`agent.config.json` and `CLAUDE.md`.

Commit the harness afterwards — it must be tracked in git or the fresh worktree
won't have it:

```bash
git add -f .claude/ scripts/ CLAUDE.md agent.config.json
git commit -m "Add autonomous engineering harness"
```

## Shell aliases (optional)

```bash
echo "source ~/claude-harness/aliases.sh" >> ~/.bashrc && source ~/.bashrc
```

Then: `ticket 42` · `tonight 2 5` · `tickets` · `parked` · `agentlog`

## Daily use

```bash
./scripts/run-ticket.sh 42        # one ticket
./scripts/run-night.sh 2 5        # 2 in parallel, 5 total
```

Exit codes: `0` PR opened · `3` parked for a human · other = harness error.

See `SETUP.md` for scheduling, ticket-system credentials, and known limitations.

## Requirements

`claude` · `git` · `jq` · plus `gh` (GitHub) or `curl` (Jira/Linear).

Linux and WSL are tested. macOS needs `brew install bash coreutils` and has known
issues with `timeout` and `mapfile` — see SETUP.md.
