# Phase 16 — RampJump Playability Retune

## Summary

Phase 16 retunes `RampJump` from a spectacle-first jump into a low-risk, low-reward obstacle. Default and normalized RampJump states should stay conservative, the approach into the ramp should be smoother than Phase 15, and successful traversal should no longer depend on achieving a dramatic airborne launch. Hard landings that remain controllable should be allowed.

## Implementation

- Tighten RampJump defaults and lever bounds to a conservative playable envelope.
- Add a shared RampJump normalizer/tuner used by agent-facing proposal paths so plain `"add ramp in sector N"` requests stay mild even when the LLM tries to overbuild.
- Increase base smoothing in `RampJumpPath` so steep legal ramps blend into the track more gradually.
- Retune RampJump integrity to accept mild pop-or-rollover traversal:
  - require meaningful vertical displacement and clean exit/reacquire,
  - stop requiring minimum airborne distance as a hard pass condition.
- Add RampJump-specific landing stabilization in verifier control so harsh but recoverable landings are damped instead of immediately spinning into failure.
- Keep a short RampJump recovery window alive after target-sector exit so late landings do not instantly hand an unstable car to the downstream sector.
- Reorder/soften RampJump repair behavior so repairs prefer making the obstacle safer rather than chasing more launch.

## Tests

- Add `TestPhase16.luau` as a fast ramp-focused suite.
- Cover conservative initial/default RampJump states, safe LLM normalization of oversized RampJump proposals, smoother base-slope blending, softened integrity acceptance for non-dramatic traversals, and a live targeted sector-3 RampJump attempt that proves playable traversal.
- Keep `phase15` and `phase4_rampjump` green.

## Assumptions

- RampJump remains the same public mechanic and lever set.
- The retune intentionally reduces spectacle ceiling for normal requests in favor of reliability and playability.
