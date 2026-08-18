---
description: Switch or configure the ticket system adapter (GitHub / Jira / Linear)
argument-hint: [github|jira|linear]
---

Configure which ticket system this project uses.

If `$1` is empty, ask the human which one they want:

> Which ticket system should this project use?
>   1. GitHub Issues  — needs `gh auth login`
>   2. Jira           — needs `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`
>   3. Linear         — needs `LINEAR_API_KEY`

Then:

### 1. Check the adapter exists

`scripts/adapters/<name>.sh` must be present and executable. If it is missing, say so
and stop — do not invent one.

### 2. Verify credentials before writing anything

- **github** — `gh auth status`. Also confirm the repo has issues enabled.
- **jira** — check all three variables are set, then a single authenticated request to
  `$JIRA_BASE_URL/rest/api/3/myself`.
- **linear** — check `LINEAR_API_KEY` is set, then the GraphQL `viewer { id }` query.

If credentials are missing or rejected, tell the human exactly which variables to set
and where to get them. Then stop. Writing a config that cannot authenticate just moves
the failure to 3am.

### 3. Confirm the ready label

Read `tickets.ready_label` from `agent.config.json` (default `agent-ready`) and check
it exists in the ticket system. For GitHub:

```
gh label list | grep agent-ready || gh label create agent-ready \
  --description "Ready for autonomous agent" --color 0E8A16
```

For Jira and Linear, tell the human to create the label manually — creating labels via
those APIs needs permissions the agent should not assume it has.

### 4. Confirm the base branch

```
git symbolic-ref refs/remotes/origin/HEAD | sed 's|.*/||'
```

Set `tickets.base_branch` to that. Do not assume `main`.

### 5. Write the config

Update only the `tickets` block in `agent.config.json`. Leave everything else alone.

### 6. Prove it end to end

Fetch one real ticket through the adapter and show the human the first few lines:

```
./scripts/adapters/<name>.sh list_ready <label>
./scripts/adapters/<name>.sh fetch <an-id>
```

If both work, the adapter is configured. If `list_ready` returns nothing, that may
just mean no tickets carry the label yet — say so rather than reporting a failure.

### 7. Report

State the adapter, the base branch, the ready label, credential status, and how many
tickets currently carry the label. If anything is unset, list the exact commands the
human needs to run.
