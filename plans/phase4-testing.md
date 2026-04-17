# Phase 4 Testing Notes

## Core Rule

Preserve the current startup lap as a flat control run. Do not inject pads or mechanics into the automatic boot flow.

The testing model for Phase 4 is:

1. boot flat track
2. run flat baseline lap
3. assert baseline succeeded
4. author one target straight sector
5. inspect geometry directly
6. reset verifier car
7. run a second full lap if runtime validation is needed
8. assert on returned `RunResult`
9. restore the sector to flat

## Why This Split

- the flat boot lap remains the clean baseline used for slowdown comparisons
- startup failures remain easy to diagnose because authored-content failures are not mixed into boot
- pads can be validated cheaply via geometry assertions before any live-lap authored-content tests
- `RampJump` is the best first live authored mechanic because current Phase 3 metrics already expose airborne and reacquire behavior
- `Chicane` should be last because current telemetry does not yet prove alternating lateral deflections

## Recommended Early Test Cases

### Pads

- `baseline_control_still_complete`
- `pads_none_creates_no_parts`
- `pads_boost_and_brake_create_expected_named_parts`
- `pads_reapply_replaces_stale_parts`
- `pads_apply_does_not_break_traversal`

### RampJump

- `rampjump_build_creates_ramp_and_landing`
- `rampjump_gap_has_no_middle_part`
- `rampjump_ramp_tilt_is_positive`
- `rampjump_invalid_length_errors`
- `rampjump_second_lap_completes`
- `rampjump_second_lap_airborne`
- `rampjump_second_lap_reacquired`
- `rampjump_bad_shape_rejected_or_fails_run`

## Runtime Assertions for First RampJump Slice

For the first legal authored jump, the second-lap run should at minimum satisfy:

- `result.success == true`
- `result.metrics.airborne == true`
- `result.metrics.air_distance > 0`
- `result.metrics.reacquired == true`
- `result.metrics.lap_time > 0`

This is enough for the first authored-mechanic slice. Full mechanic-integrity enforcement remains a Phase 5 concern.
