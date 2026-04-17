# Phase 5 — Metrics Collection and Mechanic Integrity Evaluators

## Status: COMPLETE (commit 394a567)

## Context

Phases 1–4.5 complete. Phase 5 delivers canonical `RunResult` and `FailurePacket` generation: the integrity evaluators that decide whether a completed lap qualifies as a valid RampJump, Chicane, or CrestDip, and the wiring that converts raw lap telemetry + mechanic state into the structured output the Phase 6 repair agent consumes.

Scaffolding existed in `src/integrity/` from a previous agent but had correctness bugs and no tests.

---

## What existed (scaffolded, had bugs)

| File | Status at start |
|---|---|
| `src/integrity/RampJumpIntegrity.luau` | Scaffolded — wrong `require` paths |
| `src/integrity/ChicaneIntegrity.luau` | Scaffolded — wrong `require` paths |
| `src/integrity/CrestDipIntegrity.luau` | Scaffolded — wrong `require` paths |
| `src/integrity/LapEvaluator.luau` | Scaffolded — two correctness bugs |
| `src/verifier/MetricCollector.luau` | Complete |
| `src/common/LevelMappings.luau` | Had invalid Luau type annotations |

---

## Bugs fixed

### Bug 1 — Hints dropped in LapEvaluator.evaluate

`evaluate()` called the per-mechanic evaluator and received `(ok, hints)`, but hints were never returned — silently discarded on mechanic_integrity_failure. `buildFailurePacket` accepts hints as a parameter but had no way to get them after `evaluate()`.

**Fix:** Changed `evaluate()` return type to `(RunResult, { string })`. Callers destructure both.

### Bug 2 — legalLevers always empty

`buildFailurePacket` hardcoded `legalLevers = {}`. 

**Fix:** Wire `LevelMappings.NUMERIC_LEVERS[state.mechanic]`.

### Bug 3 — No downstream_failure classification

`FailureDetector` emits `local_execution_failure` regardless of sector. Phase 5 needs to distinguish failures in the target sector vs. propagated failures.

**Fix:** Added `targetSectorId: number` parameter to `evaluate()`. Reclassifies `local_execution_failure` in a non-target sector as `downstream_failure`.

### Bug 4 — Wrong require paths in all integrity files

All four files used `script.Parent.Parent.common.Types` which resolves to `AutoTrackCore.common` — but `src/common/` maps to `ReplicatedStorage.AutoTrackCommon`, not to AutoTrackCore. These modules had never been `require`d before (Phase 4 didn't use integrity evaluators), so the bug was latent.

**Fix:** Changed all requires to `ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("...")`.

### Bug 5 — Invalid Luau syntax in LevelMappings

`LevelMappings.NUMERIC_LEVERS: { [string]: { string } } = { ... }` — the `:` after a table field access is parsed as method-call syntax in Luau, not a type annotation.

**Fix:** Removed all type annotations on table field assignments.

---

## Files changed

| File | Change |
|---|---|
| `src/integrity/LapEvaluator.luau` | Fix hints return, downstream reclassification, legalLevers, require paths |
| `src/integrity/RampJumpIntegrity.luau` | Fix require paths |
| `src/integrity/ChicaneIntegrity.luau` | Fix require paths |
| `src/integrity/CrestDipIntegrity.luau` | Fix require paths |
| `src/common/LevelMappings.luau` | Remove invalid Luau type annotations |
| `src/orchestrator/TestPhase5.luau` | **New** — 21 unit tests |
| `src/orchestrator/TestRunner.server.luau` | Add `phase5` and `phase5_unit` commands |

---

## Test coverage (21 unit tests, all SkipBootBaseline compatible)

**RampJumpIntegrity (5 tests):**
- `rampjump_pass` — valid state + airborne + reacquired → pass
- `rampjump_fail_gap` — gap_length < RAMPJUMP_MIN_GAP → fail with hint
- `rampjump_fail_not_airborne` — airborne=false → fail
- `rampjump_fail_air_distance` — air_distance < threshold → fail
- `rampjump_fail_no_reacquire` — reacquired=false → fail

**ChicaneIntegrity (3 tests):**
- `chicane_pass` — amplitude=8, transition_length=15 (curvature=0.53 > 0.05) → pass
- `chicane_fail_amplitude` — amplitude < minimum → fail
- `chicane_fail_curvature` — amplitude/transition_length < minimum → fail

**CrestDipIntegrity (4 tests):**
- `crestdip_pass` — valid params + runtime displacement → pass
- `crestdip_fail_param` — height_or_depth < minimum → fail
- `crestdip_fail_runtime` — vertical_displacement < minimum → fail
- `crestdip_fail_no_reacquire` — reacquired=false → fail

**LapEvaluator.evaluate (4 tests):**
- `evaluator_lap_failure_takes_precedence` — lapFailure preempts integrity check
- `evaluator_integrity_fail_hints_returned` — hints non-empty on mechanic_integrity_failure
- `evaluator_success` — valid lap + valid state → success=true, hints={}
- `evaluator_downstream_reclassify` — failure in non-target sector → downstream_failure

**LapEvaluator.buildFailurePacket (5 tests):**
- `failurepacket_legal_levers_rampjump` — correct levers from LevelMappings
- `failurepacket_legal_levers_chicane` — correct levers
- `failurepacket_legal_levers_crestdip` — correct levers
- `failurepacket_pads_present` — pads = { "ingress", "egress" }
- `failurepacket_hints_threaded` — hints forwarded into diagnostics.hints

---

## Verification

```lua
-- SkipBootBaseline (fast, recommended):
workspace:SetAttribute("AutoTrack_SkipBootBaseline", true)
-- start Play, then:
game.ReplicatedStorage:WaitForChild("AutoTrack_TestCmd", 5):FireServer("phase5_unit")
-- Expected: 21/21 [TEST PASS]
```

---

## Notes for Phase 6

- `LapEvaluator.evaluate` now returns `(RunResult, { string })` — callers (AttemptRunner) must destructure both returns
- `targetSectorId` is the job's intended target, NOT `lapFailure.sector_id` — pass the job's target
- `AttemptRunner.run` in `src/orchestrator/AttemptRunner.luau` is still stubbed with `error("not yet implemented")` — Phase 6 implements it
- `LapEvaluator` asserts on unknown mechanic (fail fast) — this is intentional
