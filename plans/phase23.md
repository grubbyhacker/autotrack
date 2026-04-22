# Phase 23 — Endurance Tuning Milestone

This is the authoritative Phase 23 plan file for this milestone.

## Summary

Phase 23 promotes the Phase 21 tune lab from a tune-only experiment surface into
the main mechanic-tuning workflow for endurance-mode balance changes.

The goal is a new **balanced-risk** production baseline:

- more scoring upside per sector
- more room for repair agents to participate
- fewer minimum-valid conservative commits
- no loss of the single-session, single-threaded Studio bridge contract

This phase is not a free-form optimizer. It adds the controls and observability
needed to tune quickly and independently, then promotes a more aggressive
production baseline for all three mechanics.

## Chosen defaults

- reliability posture: **balanced risk**
- first mechanic: **Chicane**
- promotion scope: **numeric baseline + scoring/objective incentives + prompt wording**
- authoritative validation remains **full-lap** outside isolated tuning
- maintained Studio verification remains **sequential only**

## Goals

- Use isolated tuning to compare the staged candidate against the current
  production baseline without restarting full endurance flows for every trial.
- Expose both tune-lab heuristic scoring and production `ChallengeScore`
  signals side by side.
- Promote a less conservative production baseline for:
  - verifier base speed and mechanic entry-speed factors
  - production defaults and legal bounds
  - scoring penalties / budget pressure that currently over-favor safe variants
  - agent-facing prompt/objective wording that still anchors to old
    conservative assumptions
  - endurance post-commit challenge-up so a clean but undershot proposal gets
    one proposer-owned do-over plus a short repair leash
- Keep reset/revert/compare/promotion workflows explicit and machine-readable.

## Non-Goals

- No hidden autonomous tuning loop.
- No parallel Studio bridge execution.
- No new public mechanic types.
- No tracked-file writes from slash commands.

## Course of Action

### 1. Tune workflow upgrades

- Add a production-baseline snapshot for the active tune mechanic.
- Make `/tune reset` restore that production baseline rather than a raw
  zero-pad lab state.
- Add `/tune compare <n>` to run:
  1. production baseline
  2. current staged candidate
  over the same isolated pass count, sequentially, with parseable comparison
  output.
- Add `/tune promote` to publish a promotion snapshot for the current staged
  candidate without mutating tracked files.
- Publish comparison / promotion data through `UIState` tune attrs so the
  coding agent can work from structured state instead of camera intuition.

### 2. Mechanic order

- Tune `Chicane` first.
- Then **pause** and review:
  - whether base speed is still too low or too high
  - whether scoring still over-rewards safe pads
  - whether compare telemetry is missing key failure margins
  - whether repair complexity is being over-penalized in endurance ranking
- Apply lessons from that pause before tuning `CrestDip`.
- Tune `RampJump` last because it still has the highest full-lap reliability
  sensitivity and depends most on entry/landing behavior.

### 3. Production promotion targets

- Raise the production risk envelope by retuning:
  - `Constants`
  - `LevelMappings`
  - proposal defaults / default pads
  - endurance objective weighting
  - proposal/orchestrator prompt wording
- Re-enable endurance challenge-up as a proposer-owned branch:
  - baseline commit still happens first
  - the proposer receives hard run metrics plus score/budget headroom
  - repairs may try to salvage the aggressive branch briefly
  - the aggressive branch only supersedes the baseline when it validates and
    improves score under budget
- Keep reliability history as telemetry / memory for future choices rather than
  a direct objective-score penalty for repaired or previously unreliable sectors.
- Keep repair flows conservative relative to the new baseline, not the old
  low-risk baseline.

## Observability / Controls

- Per-pass records must expose:
  - tune heuristic score
  - production `ChallengeScore`
  - failure type/detail
  - entry/min/exit speed
  - slowdown
  - mechanic-specific containment / reacquire / airtime metrics when present
- Per-batch records must expose:
  - success/failure counts
  - heuristic aggregate
  - production-score aggregate
  - baseline-vs-candidate delta
- Tune telemetry must include:
  - active production baseline snapshot
  - last compare snapshot
  - explicit promotion snapshot

## Test Plan

- Add `src/orchestrator/TestPhase23.luau`.
- Wire `phase23` through:
  - `src/orchestrator/TestDispatcher.luau`
  - `tools/test_bridge_config.json`
  - `Makefile`
- Cover:
  - production baseline snapshot / reset behavior
  - compare output structure and candidate-vs-baseline delta
  - explicit promotion snapshot output
  - side-by-side tune/prod scoring publication
  - prompt/objective removal of obsolete conservative framing
  - proposer-owned endurance challenge-up prompt / gate / telemetry contract
  - target reliability as a real proposal-bias input, not prompt-only text
  - endurance objective preference for higher-upside balanced-risk candidates

## Verification

- `make test-contracts`
- `make test TEST=phase21`
- `make test TEST=phase21_experiment`
- `make test TEST=phase23`
- `make test TEST=phase14_5`
- `make test TEST=phase14_integration`

## Exit Criteria

- The tune lab can compare staged candidates against the production baseline in
  one command and emit parseable results.
- Production defaults are visibly less conservative and provide more scoring /
  repair opportunities.
- Endurance objective and prompt language no longer steer the system back to the
  old low-risk baseline.
- The maintained Studio bridge flow remains sequential and green.
