# Pilot tracking

Fill one row per ticket. Two weeks, then decide on wider rollout.

| # | Repo | Ticket | Outcome | Cost | Human minutes | Notes |
|---|---|---|---|---|---|---|
|   |      |        |         |      |               |       |

**Outcome** is one of:

- `merged-clean` — merged with no edits
- `merged-edited` — merged after human changes
- `parked-right` — parked, and parking was correct
- `parked-wrong` — parked, but it should have proceeded (a harness bug)
- `bad-merge` — merged, then caused a problem

## The decision

After 15–20 tickets:

| Signal | Reading |
|---|---|
| `merged-clean` ≥ 30% | Worth rolling out |
| `merged-clean` < 30%, `parked-right` high | Ticket quality problem — fix the tickets first |
| `parked-wrong` > 20% | Harness problem — fix before anyone else uses it |
| Any `bad-merge` | Stop. Understand it fully before continuing |
| Human minutes per merged PR > 20 | The review burden cancels the benefit |

Track cost honestly, including parked runs. The comparison that matters is not
"$3 versus an engineer's hourly rate" but "$3 plus 15 minutes of senior review
versus doing it yourself in 25 minutes."
