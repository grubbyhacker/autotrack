# Phase 25 — Endurance Score/Objective Realignment

## Summary

Phase 25 realigns endurance decision policy around **realized committed score gain** instead of repair-language heuristics, removes explicit pad-use score penalties, and keeps budget pressure as a hard shaping signal.

Goals:

1. remove explicit scoring penalties tied to pad side/value
2. ensure endurance orchestration ranks candidates by realized outcomes under budget
3. preserve a light exploration nudge so one mechanic is not starved by short-run history

## Implementation Changes

### 1) Challenge scoring policy (pad-neutral)

- Update `src/integrity/ChallengeScore.luau`:
  - remove explicit deductions for:
    - Chicane ingress brake
    - CrestDip egress brake
  - keep score components driven by telemetry only:
    - `air`
    - `lateral`
    - `near_miss`
    - `time_cost`
- Remove now-unused penalty constants from `src/common/Constants.luau`.

### 2) Endurance objective policy (realized-yield first)

- Update `src/orchestrator/EnduranceObjective.luau`:
  - add mechanic-level `realized_yield` from `attempt_history`:
    - commit rate for that mechanic
    - average committed score for that mechanic (normalized)
  - add small `exploration_bonus` for underused mechanics in recent history
  - keep reliability as telemetry (`reliability_index`), not a direct repair-count penalty
  - include new constants-backed objective weights
- Add objective constants in `src/common/Constants.luau`:
  - base gain / novelty / repeat / budget risk
  - realized-yield weight
  - exploration weight
  - normalization and neutral defaults for realized-yield

### 3) Orchestrator prompt policy

- Update `src/agent/OrchestratorPromptBuilder.luau` system prompt:
  - replace "repairable risk" framing with:
    - maximize realized committed score gain under endurance budget
  - instruct orchestrator to treat committed outcomes in `attempt_history` as ranking truth.

### 4) Test updates for new policy and current invariants

- Update score-policy tests:
  - `src/orchestrator/TestPhase11.luau` verifies no explicit ingress/egress pad penalty.
- Update orchestrator-policy tests:
  - `src/orchestrator/TestPhase23.luau` verifies new prompt wording and realized-yield impact.
- Align fast-gate legacy expectations to current contracts:
  - `src/orchestrator/TestPhase6.luau`
  - `src/orchestrator/TestPhase9.luau`
  - `src/orchestrator/TestPhase14.luau`
  - `src/orchestrator/TestPhase14_5.luau`

## Verification

Executed and passing:

- `make test-contracts`
- `make test TEST=phase6_unit`
- `make test TEST=phase9_unit`
- `make test TEST=phase11_unit`
- `make test TEST=phase14_unit`
- `make test TEST=phase14_5`
- `make test TEST=phase23`
- `make refactor_fast`

## Notes

- Phase 25 does not introduce a new slash-command surface.
- Endurance budget refresh behavior remains Phase 24 contract:
  - update budget signal from committed full-lap outcomes, not isolated/reverted stages.
