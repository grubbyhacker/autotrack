# Phase 15 — RampJump Continuous Entry Arc

## Summary

Phase 15 is a narrow RampJump reliability pass. Keep the existing mechanic schema and lever set, but replace the current single angled slab with a continuous segmented climb that blends out of the flat straight before the main incline. The jump can still fail from lack of speed or bad landing, but it must no longer behave like a blunt wall at the base.

## Implementation

- Add a shared `RampJumpPath` helper used by both geometry and waypoint generation.
- Rebuild `RampJumpBuilder` from multiple short collision segments:
  - flat entry/runout remain continuous to the sector boundary,
  - the authored climb starts with a smooth blend into the requested ramp angle,
  - the gap remains the only intentional discontinuity.
- Update straight-sector waypoint generation so RampJump drive guidance follows the authored vertical profile instead of a flat straight.
- Add a small prompt guardrail telling the LLM to avoid wall-like RampJump entries and prefer climbable jump shapes.

## Tests

- Add `TestPhase15.luau` as the dedicated update gate.
- Assert RampJump builds multiple climb segments, starts flat, increases pitch smoothly before the full incline, and still reaches the sector exit after landing.
- Assert RampJump waypoint generation follows the vertical profile and preserves a continuous runout after landing.
- Keep existing RampJump smoke coverage in `phase4_rampjump` as the maintained live traversal check.

## Assumptions

- `RampJump` bounds and defaults stay unchanged in this update.
- A smooth climbable connection is sufficient to remove the wall-hit behavior without retuning legal max angle.
