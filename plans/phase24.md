# Phase 24 — Endurance Isolated Propose/Repair With Commit-Lap Gate

## Summary

Endurance build attempts should no longer pay a full-lap simulation cost on every proposal/repair step. This phase introduces a two-stage endurance verification profile:

1. `isolated_sector` batch (3 passes, fail-fast) for fast local vetting.
2. One full-lap commit gate only after isolated passes succeed.

The profile applies to:

- main endurance proposal/repair loop
- proposer-owned endurance challenge-up branch

Hotfix mode remains unchanged.

## Key behavior

- Endurance/non-endurance split:
  - Endurance-origin jobs (`request.origin == "endurance"`) use isolated-first verification.
  - Non-endurance jobs keep current single full-lap verification behavior.
- Isolated batch policy:
  - Pass count: `3`.
  - All must pass.
  - Fail-fast on first isolated failure.
- Commit gate policy:
  - Run exactly one full-lap verification after isolated success.
  - Commit only if this full-lap gate succeeds.
- Repair packet source:
  - If isolated stage fails, repair packet is built from that isolated failure.
  - If commit-lap stage fails, repair packet is built from that full-lap failure.
- Budget/slowdown authority in endurance orchestration:
  - Refresh from committed job full-lap (`job.final_result.metrics.slowdown_ratio`) only.
  - Isolated-stage outcomes must not rewrite endurance budget signal.

## Interfaces / telemetry

- Extend attempt telemetry shape (backward-compatible additions on `AttemptRecord`):
  - `verification_stage`: `"lap" | "isolated" | "commit_lap"`
  - `run_scope`: `"lap" | "isolated_sector"`
  - `isolated_passes_required`: number?
  - `isolated_passes_completed`: number?
- Keep existing result/hints fields unchanged.

## Files to change

- `src/orchestrator/JobRunner.luau`
  - Add endurance verification profile helper.
  - Use helper in main loop and challenge-up loop.
  - Emit stage-aware traces and UI phase labels.
  - Store stage metadata on attempt records.
- `src/orchestrator/OrchestratorAgent.luau`
  - Budget/slowdown refresh from commit-lap result only.
- `src/common/Constants.luau`
  - Add isolated-pass count constant.
- `src/common/Types.luau`
  - Add optional attempt telemetry fields for verification stage metadata.
- `src/orchestrator/TestPhase24.luau`
  - New phase suite with unit-style assertions for profile behavior.
- `src/orchestrator/TestDispatcher.luau`
  - Add `phase24` routing.
- `tools/test_bridge_config.json`
  - Add `phase24` suite contract.
- `Makefile`
  - Add `phase24` make target.

## Test cases

`TestPhase24` should assert at minimum:

1. Endurance profile runs isolated passes before commit-lap and applies action once.
2. Isolated-stage failure short-circuits and skips commit-lap.
3. Commit-lap failure is surfaced as commit-lap stage result.
4. Non-endurance profile remains single full-lap.
5. Orchestrator slowdown refresh only updates from committed full-lap results.

## Validation commands

- `make test-contracts`
- `make test TEST=phase24`
- `make test TEST=phase22_endurance_entry`
- `make test TEST=phase23`

## Assumptions

- Endurance is the only production-priority mode moving forward; non-endurance behavior is preserved only for compatibility/regression safety.
- Commit-lap remains the authoritative safety/budget gate before sector commit.
- No slash-command expansion is introduced in this phase.
