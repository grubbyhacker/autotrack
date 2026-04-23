# Phase 27 — Return of RampJump

## Summary

Phase 27 restores RampJump as a high-risk/high-reward mechanic without turning repair outcomes into neutral geometry. The phase ships production behavior plus tune-lab-driven experimentation, keeps global `STRAIGHT_LENGTH` fixed, introduces RampJump-local runout allocation, and adds a dual ramp profile path (`linear_blend` vs `curved_lift`) with a controlled promotion gate.

## Implementation Changes

- Rework RampJump proposal/normalization policy to remove legacy conservative clamps and forced default brake pads.
- Introduce mode-aware RampJump tuning (`opening`, `challenge_up`, `repair`) so opening/challenge proposals can be bold while repair remains corrective without flattening to trivial jumps.
- Retune RampJump repair heuristics around failure evidence:
  - `no_progress` / uphill bleed: ingress boost first, then geometry softening.
  - reacquire/landing instability: landing+gap/runout corrections before blanket braking.
  - downstream instability: preserve recoverable exit behavior without always collapsing challenge.
- Add a RampJump repaired-commit score-retention gate in `JobRunner`:
  - for repaired RampJump successes, require committed score >= `max(0.70 * prior_best_success_score, score_band_floor)`.
  - floor mapping: `medium=5.5`, `high=7.5`, `extreme=9.0`.
  - if gate fails, classify as repair-needed and continue within attempt budget.
- Recalibrate RampJump runtime integrity thresholds for the post-entry-snap era to reduce false failures on visually valid jumps.
- Add orientation-aware landing acceptance:
  - capture touchdown telemetry (`target_touchdown_up_dot`, `target_touchdown_down_speed`).
  - allow higher exit angular/vertical speed only when touchdown up-dot clears a configured upright threshold.
- Keep `Constants.STRAIGHT_LENGTH` global/fixed and add RampJump-local effective-length behavior via explicit runout allocation (`entry` + `feature` + `exit`) instead of pure centering.
- Add RampJump dual profile support:
  - `linear_blend` (existing baseline behavior)
  - `curved_lift` (brachistochrone-inspired lift emphasis)
  - runtime-selectable via `AutoTrack_RampJumpProfileMode` and production default constant.
- Follow-up endurance pass for weaker/over-conservative repair models:
  - remove blanket "make it easier" phrasing from the final repair user turn.
  - sanitize RampJump LLM full-state repairs inside `LLMAdapter` with deterministic guardrails:
    - bounded per-attempt lever deltas,
    - bounded cumulative drift from first proposed RampJump shape,
    - `no_progress` boost-first constraints (no climb lengthening),
    - anti-brake-escalation constraints for speed-bleed/downstream-speed failures.
- Follow-up stability/modeling pass for on-ramp spin/crash behavior:
  - add grounded RampJump surface stabilization in `VerifierController` (windowed angular damping + lateral side-slip damping) so the car does not unnecessarily spin on ramp/landing contact.
  - add repeated zero-progress instability escape in RampJump full-state repair sanitization:
    - if recent consecutive failures are `body_off_track`/`tumble`/similar with low target progress, automatically step down excessive ingress boost and soften jump geometry while preserving challenge.
  - add upright-touchdown reacquire bonus in runtime RampJump integrity: borderline reacquire-distance cases can pass when touchdown orientation and exit energy remain controlled.
- Follow-up containment/challenge-up pass for endurance with weaker models:
  - fix verifier containment/off-track false positives by using cross-track centerline distance (not clamped segment-distance artifacts) for RampJump guidance and correction.
  - add RampJump-only grounded-window containment forgiveness in `VerifierController`: when centerline reacquire stays within a configurable corridor and the car remains upright, do not immediately fail on front-footprint swing.
  - block RampJump proposer `challenge_up` do-over in two cases:
    - the committed RampJump success required repairs (`attempt_index > 0`)
    - the committed RampJump baseline is already high-energy (near-top geometry + strong ingress boost).

## Public Interfaces / Types

- Extend `RunMetrics` with:
  - `target_touchdown_up_dot: number?`
  - `target_touchdown_down_speed: number?`
- Add RampJump runtime attrs/constants for:
  - profile mode selection
  - landing upright threshold
  - hard-landing exit comfort caps
- No changes to `Request`, `SectorState`, or public mechanic lever schema.

## Test Plan

- Add `src/orchestrator/TestPhase27.luau` with assertions for:
  - repaired RampJump score-retention gate behavior
  - upright-aware hard-landing acceptance path
  - runout allocation preserving sector completeness
  - dual profile generation (`linear_blend` and `curved_lift`) and lift differentiation
  - ramp profile mode runtime override behavior
  - repair prompt wording avoids blanket "make easier" directive
  - RampJump LLM full-state repair guardrails prevent `no_progress` flattening/brake escalation
  - repeated zero-progress instability guardrails step down excessive boost and soften geometry
  - verifier RampJump grounded-surface stabilization helpers engage in-window and damp angular/lateral instability
  - upright-touchdown reacquire bonus path
- Wire `phase27` through:
  - `src/orchestrator/TestDispatcher.luau`
  - `tools/test_bridge_config.json`
  - `Makefile`

## Verification

- `make test TEST=phase27`
- `make test TEST=phase20`
- `make test TEST=phase21_unit`
- `make test TEST=phase21_experiment`
- `make test TEST=phase23`
- `make test TEST=phase24`
- `make test TEST=phase14_integration`
- `make endurance-trace MODEL=google/gemma-3-4b-it DURATION=60 OUT=traces/endurance-gemma-after-stability.json`
- `make endurance-trace MODEL=google/gemma-3-4b-it DURATION=90 OUT=traces/endurance-gemma-after-containment.json`
- `make endurance-trace MODEL=google/gemma-3-4b-it DURATION=60 OUT=traces/endurance-gemma-after-challenge-gate.json`

## Assumptions

- Scope is production + tune-lab experimentation in this phase.
- Global straight length remains fixed; RampJump-local allocation handles feel differences.
- Curved profile ships behind controlled mode selection and must pass regression before becoming the production default.
- Score-retention gate is the anti-neutralization contract for repaired RampJump commits.
