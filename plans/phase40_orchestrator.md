# Phase 40 — Strict Typing Campaign Orchestrator

## Status

Complete.

Phase 40 adds a deterministic shell orchestrator plan and implementation for bounded strict-typing migration campaigns. The orchestrator is intentionally not an LLM: it is a readable shell loop that launches stateless `codex exec` workers serially, gives each worker one file attempt, and decides whether the campaign continues from explicit state, budgets, and STOP markers.

Current campaign baseline from Phase 39: `27 / 107` Luau files are `--!strict`. The remaining Luau files are unmarked; there are currently no `--!nonstrict` or `--!nocheck` files. `make typecheck` is the authoritative analyzer gate, with `make fmt-check`, `make lint`, `make test-contracts`, and narrow phase/refactor targets used when relevant to a selected file.

## Deliverables

- `tools/strict_typing_campaign.sh`
  - Runs a serial deterministic campaign loop.
  - Invokes one bounded `codex exec` worker per iteration.
  - Reads and updates a Markdown campaign state file.
  - Halts on STOP, completion, wall-clock budget, invocation budget, no-progress budget, worker timeout, worker error, or state corruption.
  - Uses PowerShell as the primary notification mechanism in this WSL/Windows environment, with terminal bell output as fallback.
- This plan file, including the state schema, worker prompt contract, budgets, short-duration test, and failure behavior.
- `.gitignore`
  - Ignores local strict-typing campaign state files and campaign logs so unattended runs do not pollute `git status`.

No Roblox MCP server or Studio path is part of this phase. The campaign operates only on text files and local `make` gates.

## Shell Architecture

Run shape:

```sh
tools/strict_typing_campaign.sh plans/strict_typing_campaign_state.md
MAX_SECONDS=3600 tools/strict_typing_campaign.sh plans/strict_typing_campaign_state.md
MAX_INVOCATIONS=3 MAX_SECONDS=1800 tools/strict_typing_campaign.sh /tmp/strict-smoke.md
```

Environment knobs:

- `MAX_SECONDS`, default `14400` seconds / 4 hours. This is checked between workers, so an in-flight worker is allowed to finish or hit its own timeout.
- `MAX_INVOCATIONS`, default `40`.
- `WORKER_TIMEOUT_SECONDS`, default `600` seconds. This is the hard anti-runaway guard for a stuck worker.
- `NO_PROGRESS_LIMIT`, default `3`.
- `CODEX_CMD`, default `codex`.
- `STATE`, from the first script argument or `plans/strict_typing_campaign_state.md`.

Loop behavior:

```sh
require a clean worktree except the campaign state file and logs/
require STATUS: running in the state file

while true:
  reload state header
  halt if STOP, terminal status, corrupt state, exhausted time, exhausted invocations, no progress, or queue complete
  identify queue item at NEXT_INDEX
  record before commit and strict count
  render worker prompt with the state path
  run timeout WORKER_TIMEOUT_SECONDS codex exec ...
  record worker output under logs/strict_typing_workers/
  if worker failed or timed out, mark STATUS: error and notify
  compare commit and strict count
  reset or increment NO_PROGRESS_COUNT
  increment INVOCATIONS_STARTED
```

The orchestrator owns continuation. Workers can set `STATUS: stop` and `STOP_REASON`, but they do not loop, choose a second file, or decide whether the campaign continues.

## State File Schema

The state file is Markdown with a small mutable header, an explicit queue, and append-only history. It is durable shared memory, not a transcript. Workers should read this file first and keep updates terse enough for the next worker.

Iteration 0 example:

```md
# Strict Typing Campaign State

STATUS: running
STOP_REASON:
NEXT_INDEX: 1
INVOCATIONS_STARTED: 0
NO_PROGRESS_COUNT: 0
STRICT_START: 27
STRICT_CURRENT: 27
POLICY_NO_ANY_CASTS: true
POLICY_BOUNDARY_WIDENING: stop
POLICY_SPLIT_RUNTIME_VS_TEST_TYPES: stop_first_time
REQUIRED_CHECKS: make typecheck
DEFAULT_EXTRA_CHECKS: make fmt-check; make lint
NOTES: No Studio, no Roblox MCP, no gameplay retuning.

## Queue
1. src/common/Constants.luau | checks=make typecheck; make fmt-check; make lint
2. src/common/PadValueUtils.luau | checks=make typecheck; make fmt-check; make lint; make test-contracts
3. src/mechanics/ChicanePath.luau | checks=make typecheck; make fmt-check; make lint; make phase39
4. src/integrity/ChicaneIntegrity.luau | checks=make typecheck; make fmt-check; make lint; make mechanics_regression
5. src/mechanics/RampJumpBuilder.luau | checks=make typecheck; make fmt-check; make lint; make phase16

## History
```

Iteration 5 example:

```md
STATUS: running
STOP_REASON:
NEXT_INDEX: 6
INVOCATIONS_STARTED: 5
NO_PROGRESS_COUNT: 1
STRICT_START: 27
STRICT_CURRENT: 30

## History
2026-04-25T10:02:11-07:00 | index=1 | file=src/common/Constants.luau | result=success | commit=abc1234 | checks=typecheck,fmt-check,lint | learned=large constants module only needed explicit export shape
2026-04-25T10:14:30-07:00 | index=2 | file=src/common/PadValueUtils.luau | result=success | commit=def5678 | checks=typecheck,fmt-check,lint,test-contracts | learned=localized value-record aliases worked
2026-04-25T10:28:44-07:00 | index=3 | file=src/mechanics/ChicanePath.luau | result=failure_reverted | commit=unchanged | checks=typecheck | learned=Vector3 sample helper needs more careful staged attempt
2026-04-25T10:39:02-07:00 | index=4 | file=src/integrity/ChicaneIntegrity.luau | result=success | commit=987abcd | checks=typecheck,fmt-check,lint,mechanics_regression | learned=TargetRuntimeMetrics path stayed local
2026-04-25T10:49:10-07:00 | index=5 | file=src/mechanics/RampJumpBuilder.luau | result=failure_reverted | commit=unchanged | checks=typecheck | learned=builder part typing needs more careful staged attempt
```

STOP example:

```md
STATUS: stop
STOP_REASON: STOP-NEEDS-HUMAN: src/common/Types.luau migration requires widening exported RunMetrics fields used across integrity/orchestrator boundary.
NEXT_INDEX: 12
INVOCATIONS_STARTED: 11
NO_PROGRESS_COUNT: 0
STRICT_START: 27
STRICT_CURRENT: 34

## History
2026-04-25T12:21:52-07:00 | index=12 | file=src/common/Types.luau | result=STOP-NEEDS-HUMAN | commit=unchanged | checks=not_run | learned=would require exported boundary widening; policy says stop
```

Workers increment `NEXT_INDEX` only after success or reverted failure. On STOP, `NEXT_INDEX` remains pointed at the blocked file.

## Worker Prompt Contract

The orchestrator passes this prompt to every worker, replacing `{STATE_FILE}` with the active state path:

```text
You are one worker in a serial AutoTrack strict-typing migration campaign.

Read {STATE_FILE}. It is the durable shared memory for this campaign. The next worker will only have that file plus the repo, so keep your state update concise and useful.

Your authority:
- Attempt EXACTLY ONE file: the queue item at NEXT_INDEX.
- Flip only that file to the next typing tier. In this repo, remaining unmarked Luau files should normally become --!strict.
- Make the smallest local edits needed for that one file to pass checks.
- Do not use the Roblox MCP server or Studio.
- Do not retune gameplay, alter runtime behavior intentionally, or broaden the task to neighboring files unless a tiny local helper in the target file requires it.
- No `:: any` casts to silence errors. Ever.
- Do not widen exported/module-boundary types under the default policy. If needed, STOP instead.
- Nil checks, local narrowing, local type aliases, and helper constructors are allowed.
- If splitting a runtime object type from a test/helper input type is needed and this is the first such case, STOP instead of deciding the pattern yourself.

Procedure:
1. Confirm the git worktree is clean except for {STATE_FILE} and campaign logs. If not, append STOP-NEEDS-HUMAN with the dirty paths and exit.
2. Read NEXT_INDEX and select exactly that queue file.
3. Inspect only the target file and minimal directly required type/config files.
4. Edit the target file only unless a tiny same-file-adjacent test/check update is explicitly necessary. If broader edits are needed, revert and STOP.
5. Run at minimum `make typecheck`. Also run the checks listed on the queue line when relevant and not Studio/live-session dependent.
6. On success: commit the target-file migration with message `strict: promote <path>`, update STRICT_CURRENT if changed, increment NEXT_INDEX, append one History line, and exit.
7. On failure: revert your edits to the target file, leave git clean except for {STATE_FILE}/logs, increment NEXT_INDEX, append one History line with `failure_reverted`, and exit.
8. On policy boundary: do not flip the pragma, ensure git is clean except for {STATE_FILE}/logs, set STATUS: stop and STOP_REASON beginning with `STOP-NEEDS-HUMAN:`, append one History line, and exit.

Your final response should be at most five lines: attempted file, result, checks run, commit hash if any, and whether STOP was set.
```

## Budgets And Termination

- Worker timeout: `600s` default. A stuck agent cannot block forever.
- Campaign wall-clock cap: `14400s` default, configurable per invocation. Example: `MAX_SECONDS=3600 ...` for a one-hour run.
- Invocation cap: `40` default.
- No-progress cap: `3` consecutive workers without both a new commit and a strict-count increase.

Terminal states:

- `STATUS: complete` when `NEXT_INDEX` exceeds the queue.
- `STATUS: budget_exhausted` when wall-clock or invocation budget is hit before the next launch.
- `STATUS: no_progress` when the no-progress counter reaches the limit.
- `STATUS: stop` when a worker writes `STOP-NEEDS-HUMAN`.
- `STATUS: error` for worker timeout, nonzero worker exit, corrupt state, or unsafe dirty worktree.

## Notifications

PowerShell is the primary notification mechanism because it is available from this WSL environment and does not add a dependency. The script falls back to terminal bell output when PowerShell is unavailable.

Notify on:

- STOP: `Human review needed at NEXT_INDEX=<n>: <STOP_REASON>`
- Budget exhausted: `Stopped after <invocations> invocations, <elapsed> seconds, strict <start> -> <current>.`
- No progress: `Stopped after <N> consecutive non-progress workers. Next file: <path>.`
- Complete: `Queue complete. Strict <start> -> <current>. See <state> and logs/strict_typing_campaign.log.`
- Worker error: `Worker failed or timed out at NEXT_INDEX=<n>. Worktree check required.`

## Minimum Viable First Run

The first real campaign should use 5-10 curated low-risk files. Supervise the first 2-3 invocations, then leave it unattended until halt or completion.

The experiment worked if:

- The loop starts from state, launches workers serially, and never asks the human per iteration.
- Each worker attempts no more than one file.
- Success commits are clean and check-backed.
- Failed attempts are reverted and logged without poisoning the worktree.
- STOP, budget, no-progress, complete, and worker-error notifications fire correctly.
- The state file is enough for a fresh worker or human to understand the next step.

Success is independent of how many files migrate.

## Short Duration Test

Before a long campaign, run a bounded smoke test:

1. Create a temporary state file with 2-3 low-risk queue entries.
2. Run `MAX_INVOCATIONS=3 MAX_SECONDS=1800 WORKER_TIMEOUT_SECONDS=600 tools/strict_typing_campaign.sh /tmp/strict-smoke.md`.
3. Let 2-3 workers run, then confirm the orchestrator terminates by invocation cap or queue completion.
4. Verify campaign log, worker logs, state header, history lines, commits/reverts, and PowerShell notification behavior.
5. Repeat with an already-expired time budget by setting `MAX_SECONDS=0` to prove the script halts before launching a worker.

The campaign wall-clock cap intentionally does not kill an in-flight worker. `WORKER_TIMEOUT_SECONDS` is the runaway safety for a stuck worker, and the campaign cap prevents the next worker from starting once the current one exits.

## Failure Modes

- Dirty worktree before launch: refuse to start unless the only dirty paths are the state file and `logs/`.
- Worker edits multiple files unnecessarily: the worker contract requires revert and STOP if broader edits are required.
- Worker timeout: mark `STATUS: error`, notify, and exit.
- Campaign time expires during a worker: allow that worker to finish or hit its timeout, then halt before launching the next worker.
- Worker commits without strict-count increase: count as no progress; repeated cases halt.
- Analyzer environment breaks globally: workers revert; no-progress or error halts the campaign.
- Boundary type widening needed: worker sets STOP and leaves the target unmodified.
- State/header corruption: mark error and notify.
- Notification command unavailable: terminal bell/output fallback still records the event.
- Studio/live-session temptation: forbidden; this campaign uses text files plus static/narrow local gates only.
