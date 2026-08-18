# Project Instructions

<!-- Keep this file under ~2000 tokens. It is loaded on EVERY turn.
     Fill in the PROJECT SPECIFICS section per repo. The rules below are universal. -->

## Commands

All build/test commands are declared in `agent.config.json` under `commands`.
**Read that file — do not guess commands.** If a command value is an empty string, that
step does not exist in this project and must be skipped, not improvised.

## PROJECT SPECIFICS

<!-- === EDIT THIS SECTION PER REPO === -->
- **Stack:** <language / framework / version>
- **Entry points:** <where the app starts>
- **Architecture:** <2-4 lines: layers, key modules, data flow>
- **Conventions:** <naming, folder structure, error handling, logging>
- **Known landmines:** <flaky areas, legacy code to leave alone>
<!-- === END EDIT SECTION === -->

## Absolute rules

1. **`.tickets/<id>/SPEC.md` is frozen.** Never edit it, never propose editing it.
   If the spec seems wrong, stop and write that in `REPORT.md`. Do not work around it.
2. **Never weaken a test to make it pass.** Do not delete test cases, loosen assertions,
   add skips, widen tolerances, or special-case test inputs in production code.
   If a test is genuinely wrong, say so in `REPORT.md` and stop.
3. **Never hard-code a value to satisfy a specific test input.** If the fix only works
   for the cases in the test file, it is not a fix.
4. **Never touch protected paths** (listed in `agent.config.json` → `policy.protected_paths`).
   If the ticket requires it, stop and park.
5. **Never run destructive git commands.** No `push --force`, no `reset --hard` on shared
   branches, no history rewriting, no branch deletion.
6. **Never add a dependency** without stating it explicitly in `REPORT.md`.
7. **You are the only writer.** Subagents you invoke are read-only. Do not ask them to edit.

## Definition of done

A ticket is complete only when ALL of these hold:
- Every acceptance criterion in `SPEC.md` is satisfied by the actual code.
- Every configured command (`test`, `lint`, `typecheck`, `build`) passes.
- The change is minimal — no unrelated refactors, no drive-by formatting.
- `REPORT.md` exists and is honest, including about what did not work.

## Honesty requirements

`REPORT.md` must state plainly:
- What was implemented
- What was verified, and by which command
- **What was NOT done, and why**
- Assumptions made
- Anything that needs a human decision

An accurate report of partial success is a **better outcome** than a confident report of
false success. You will not be penalised for saying a ticket could not be completed.
