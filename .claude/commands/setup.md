---
description: Analyse this repository and configure the autonomous engineering harness for it
---

You are setting up the autonomous engineering harness in a repository you have never
seen. Your job is to produce two files — `agent.config.json` and `CLAUDE.md` — that are
**verified correct**, not guessed.

The single most important rule: **run every command before you write it down.** A
config full of plausible-looking commands that do not actually work is worse than no
config, because the harness will blame the agent for environment failures.

---

## Phase 1 — Detect the stack

Look for these markers and note every one you find. A repo may have several
(monorepo, or backend + frontend):

| Marker | Stack | Likely commands |
|---|---|---|
| `package.json` | Node/TS | `npm ci`, `npm test`, `npm run lint`, `tsc --noEmit` |
| `requirements.txt`, `pyproject.toml` | Python | `pip install -r ...`, `pytest`, `ruff check .` |
| `composer.json` | PHP/Laravel | `composer install`, `php artisan test`, `pint --test` |
| `go.mod` | Go | `go mod download`, `go test ./...`, `golangci-lint run` |
| `*.csproj`, `*.sln` | .NET | `dotnet restore`, `dotnet test`, `dotnet format` |
| `Gemfile` | Ruby | `bundle install`, `bundle exec rspec`, `rubocop` |
| `pom.xml`, `build.gradle` | Java | `mvn install`, `mvn test` |

Read `package.json` → `scripts` (or the equivalent) for the **actual** command names.
Do not assume `npm run lint` exists just because it usually does.

Also read: CI config (`.github/workflows/*`, `.gitlab-ci.yml`, `Jenkinsfile`). CI is
the most reliable source of truth for how this project is really built and tested.

## Phase 2 — Verify every command

For each candidate command, **actually run it** and record the result.

1. Run the install command first. If it fails, everything after it is meaningless.
2. Run test, lint, typecheck, build in turn. Time each one.
3. For any command that fails, decide which case it is:
   - **Not configured** (no lint script exists) → leave that config value as `""`
   - **Broken environment** (missing dependency) → note it for the human, leave `""`
   - **Pre-existing failures** (real lint debt, failing tests) → **this is critical**,
     see Phase 3
4. Note any command taking over 2 minutes. Slow commands make overnight runs
   expensive; mention it in your summary.

**A command that does not pass on a clean checkout must not go in the config.** The
harness treats a verification failure as "the agent broke something." If the command
was already failing before the agent touched anything, every ticket will park forever.

## Phase 3 — Check the clean-checkout trap

This catches the most common setup failure. The harness works in a fresh worktree
built from the remote branch, so anything not committed does not exist there.

1. Run `git status --short`. Any uncommitted changes that make the commands pass?
2. Run `git ls-files` and confirm every file the commands need is **tracked**:
   test files, `requirements-dev.txt`, `pyproject.toml`, lint config, `tsconfig.json`.
3. Check `.gitignore` is not excluding something the build needs.
4. If a command depends on a generated artifact that does not exist in a clean
   checkout (e.g. Next.js `.next/types` for `tsc`), either fold the generation step
   into the install command or leave that check as `""` and say why.

Report anything in this category loudly. It is the difference between a harness that
works and one that parks every ticket.

## Phase 4 — Map the architecture

Explore the codebase properly — `glob`, `grep`, read the main entry points, read the
README. You are producing the section of `CLAUDE.md` that most determines output
quality, so do not skim.

Establish:
- Entry points and how the app starts
- Directory layout and what each part is for
- **Import style** — package-relative (`from app.config import X`) or flat
  (`from config import X`)? Getting this wrong breaks every test the agent writes.
- Naming, error-handling, and logging conventions — infer from the code, not from
  what you would normally recommend
- How tests are organised and what the existing ones actually cover

## Phase 5 — Identify protected paths

Find the files where a wrong change causes damage that tests will not catch. Look for:

- Database schema and migrations
- Auth, sessions, permissions, crypto
- Payment and billing code
- Anything holding a dimension, size, or format constant that persisted data depends on
- CI config, Dockerfiles, infrastructure-as-code
- `.env*` and anything else holding secrets

Be **specific**, not broad. Protecting `backend/**` means every ticket parks.
Protecting `backend/database.py` protects the actual risk.

For each one, write down the one-sentence reason. That reason goes in `CLAUDE.md`
under Landmines, and it is what stops the agent from arguing its way around it.

## Phase 6 — Ask about the ticket system

Ask the human directly:

> Which ticket system does this project use?
>   1. GitHub Issues  (needs `gh auth login`)
>   2. Jira           (needs `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`)
>   3. Linear         (needs `LINEAR_API_KEY`)

Then verify the credentials actually work:
- GitHub → `gh auth status`
- Jira → a single authenticated `curl` to the base URL
- Linear → a minimal GraphQL query

If credentials are missing, still write the config, but tell the human exactly which
environment variables to set before the first run.

Also confirm the base branch (`main` vs `master` vs `develop`) with
`git symbolic-ref refs/remotes/origin/HEAD`.

## Phase 7 — Write the files

**`agent.config.json`** — only verified commands. Empty string for anything that
does not exist or does not pass.

**`CLAUDE.md`** — under 2000 tokens, since it loads on every turn. Structure:
project summary, stack, import style, directory layout, data flow, conventions,
landmines (with reasons), absolute rules, definition of done, honesty requirements.

Copy the Absolute Rules / Definition of Done / Honesty sections verbatim from
`templates/generic-CLAUDE.md` — they are not project-specific and they are load-bearing.

## Phase 8 — Verify the setup

1. Re-read `agent.config.json` and run each non-empty command once more.
2. Test the hooks actually block:
   ```
   echo '{"tool_input":{"file_path":"<a protected path>"}}' \
     | CLAUDE_PROJECT_DIR="$PWD" bash scripts/hooks/guard-paths.sh
   ```
   Exit code must be 2. Then test a normal source file returns 0.
3. Confirm `.claude/`, `scripts/`, `CLAUDE.md`, `agent.config.json` are all tracked
   in git. If `.claude/` is gitignored, use `git add -f`.

## Phase 9 — Report

Print a summary covering:

- Stack(s) detected
- Each command, its verified status, and its runtime
- Anything left as `""` and why
- Protected paths and the reason for each
- Ticket adapter and whether credentials are working
- **Anything the human must fix before the first run** — untracked files, missing
  credentials, pre-existing test or lint failures
- A suggested first ticket: something small and low-risk in this specific codebase

Be honest about what you could not verify. A setup that reports "3 commands verified,
2 skipped, here is why" is far more useful than one claiming everything is fine.
