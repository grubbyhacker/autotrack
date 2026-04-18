# Phase 10 — RampJump and Chicane: Crest-Level Rigor

## Summary

Apply the same standards introduced in Phase 9 for `CrestDip` to `RampJump` and `Chicane`:

- centered authored feature with geometry and verifier guidance aligned
- static failures rejected in preflight
- target-sector runtime failures rejected at the earliest conclusive moment
- full-lap continuation preserved only for downstream safety
- repair behavior tuned so pad actions visibly participate in the loop

Chosen implementation defaults:

- `RampJump` story: takeoff first, then landing stability
- `Chicane` story: speed management first, with pad-based slowing visible when needed

## Implementation

### 1. `src/integrity/RampJumpIntegrity.luau`

Split into:

- `preflight(state)`:
  - `gap_length below minimum`
- `evaluateRuntime(metrics)`:
  - `verifier never became airborne`
  - `air distance too short`
  - `semi-rail reacquisition failed after landing`
- `evaluate(state, metrics)`:
  - combined fallback

Use target-sector-local jump metrics when present.

### 2. `src/integrity/ChicaneIntegrity.luau`

Split into:

- `preflight(state)`:
  - minimum amplitude
  - positive transition length
  - minimum static curvature
- `evaluateRuntime(metrics)`:
  - runtime lateral excursion hit both sides of the centerline
  - runtime lateral band changes reached the minimum alternation threshold
- `evaluate(state, metrics)`:
  - combined fallback

Runtime criteria should be target-sector-local, not lap-global.

### 3. `src/common/Types.luau`

Extend `RunMetrics` with Chicane target-sector-local telemetry:

- `target_left_offset`
- `target_right_offset`
- `target_lateral_band_changes`

Keep the existing Crest/jump-compatible target-sector fields.

### 4. `src/common/Constants.luau`

Add Chicane runtime telemetry thresholds needed by the new evaluator:

- `CHICANE_LATERAL_BAND_THRESHOLD`

Prefer to reuse existing constants where possible:

- `CHICANE_MIN_LATERAL_DISPLACEMENT`
- `CHICANE_MIN_ALTERNATIONS`
- `CHICANE_MIN_CURVATURE`

### 5. `src/verifier/MetricCollector.luau`

Augment target-sector tracking to accumulate:

- left-side excursion magnitude
- right-side excursion magnitude
- band changes across `left / center / right`

The target-sector telemetry model should stay mechanic-agnostic enough for Crest, Jump, and Chicane to share it.

### 6. `src/integrity/LapEvaluator.luau`

Generalize `preflight(...)` so it dispatches to:

- `RampJumpIntegrity.preflight`
- `ChicaneIntegrity.preflight`
- `CrestDipIntegrity.preflight`

Continue returning the same zero-metrics `RunResult` shape for preflight failures.

### 7. `src/verifier/VerifierController.luau`

Generalize target-sector runtime checks:

- at target-sector exit, evaluate Jump and Chicane runtime integrity the same way Crest is currently evaluated
- keep Crest’s immediate over-cap airtime failure
- do not add premature early exits for Jump or Chicane unless the condition is truly conclusive before sector exit

While inside the target sector, compute the target-local lateral telemetry needed by Chicane using the target sector entry frame.

### 8. `src/orchestrator/AttemptRunner.luau`

Pass the target sector entry frame through to `VerifierController.runLap(...)` so Chicane target-local telemetry can be measured in target-sector local space.

### 9. `src/orchestrator/MinimalProposer.luau`

Tune repair ordering so pads are first-class actions in the stories:

For `RampJump`:

- takeoff failures:
  - prefer `ingress = Boost`
  - then numeric takeoff increases
- landing/reacquire failures:
  - prefer `egress = Brake`
  - then soften landing geometry

For `Chicane`:

- local execution / unstable traversal:
  - prefer `ingress = Brake`
  - then `egress = Brake`
  - then corridor widening / transition softening
- runtime shape failures:
  - numeric edits remain primary

### 10. Tests and wiring

Add `src/orchestrator/TestPhase10.luau` with `runUnit()` and `runIntegration()`.

Unit:

- RampJump preflight hint
- RampJump runtime airborne / air distance / reacquire hints
- Chicane preflight hint
- Chicane runtime excursion / alternation hints
- proposer chooses `ENTRY BOOST` for jump takeoff failures
- proposer chooses `EXIT BRAKE` for jump landing failures
- proposer chooses `ENTRY BRAKE` for chicane instability

Integration:

- Jump request commits after a visible repair chain
- Chicane request commits after a visible repair chain
- impossible biased variants still revert within budget

Update:

- `src/orchestrator/TestDispatcher.luau`
- `tools/test_bridge_config.json`
- `Makefile`
- any older suites whose fixtures or expectations need to reflect the new timing model

## Verification

Minimum maintained verification set:

- `make phase10_unit`
- `make phase10_integration`
- `make phase4`
- `make phase6_unit`
- `make phase6_integration`
- `make phase8_unit`
- `make phase8_integration`
- `make phase9_unit`
- `make phase9_integration`

## Assumptions

- Jump and Chicane should follow Crest’s timing model rather than inventing a separate failure architecture.
- Immediate failure is only correct when the failure is already conclusive; otherwise target-sector exit is the right cutoff.
- Pad actions should remain explicit in the HUD via the existing `REPAIR ACTION` label.
