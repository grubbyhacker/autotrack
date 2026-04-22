# Phase 18 — Deterministic Sector Isolation Hardening

## Summary

Phase 18 hardens the verifier against cross-sector non-determinism by making
sector boundaries authoritative reset points and by rejecting authored sectors
that only barely survive. Full-lap visible verification remains the deciding
simulation, but each sector should now begin from a canonical stable state
instead of inheriting arbitrary upstream physics noise.

This phase explicitly prioritizes repeatability over continuity. Visible snaps
at sector boundaries are acceptable.

## Implementation

- Replace the current target-only entry normalization path with a lap-wide
  sector-entry snap in `VerifierController`.
- Snap on every sector transition:
  - centerline position at sector entry,
  - upright orientation aligned to sector-forward heading,
  - zero angular velocity,
  - forward-only linear velocity at a sector-kind / mechanic-specific canonical
    entry speed.
- Use the exact sector `entry` frame as the snap anchor when runtime sector
  metadata is available, not only the nearest waypoint position.
- After a snap, hold the snapped heading briefly before full lookahead steering
  and lateral nudging resume.
- Do not snap corner-to-corner handoffs (`Corner -> Corner`); those should stay
  continuous at corner speed.
- Keep the existing in-sector stabilization clamps as a second line of defense,
  but stop treating them as target-only behavior where that would allow
  instability to propagate through authored sectors.
- Add explicit constants for:
  - canonical entry speed factors for flat straights, corners, and each
    mechanic,
  - per-mechanic comfort margins beyond the existing integrity floors.
- Extend `RunMetrics` with margin-aware telemetry:
  - `target_reacquire_distance`
  - `target_peak_body_distance`
  - `target_exit_angular_speed`
  - `target_exit_vertical_speed`
- Populate the new fields in `MetricCollector` / verifier runtime collection.
- Tighten runtime integrity gates:
  - `RampJump`: require stronger lift, reacquire headroom, and stable exit.
  - `Chicane`: require stronger excursion plus body-containment headroom.
  - `CrestDip`: require stronger lift, apex-speed margin, airtime headroom, and
    stable exit.
- Treat borderline outcomes as hard `mechanic_integrity_failure` results.

## Files Expected To Change

- `plans/phase18.md`
- `plans/agent-handoff.md`
- `src/common/Constants.luau`
- `src/common/Types.luau`
- `src/verifier/MetricCollector.luau`
- `src/verifier/VerifierController.luau`
- `src/integrity/RampJumpIntegrity.luau`
- `src/integrity/ChicaneIntegrity.luau`
- `src/integrity/CrestDipIntegrity.luau`
- `src/orchestrator/TestPhase18.luau`
- `src/orchestrator/TestDispatcher.luau`
- `tools/test_bridge_config.json`
- `Makefile`

## Verification

Primary:

- `make test TEST=phase18`
- `make test TEST=phase16`
- `make test TEST=phase14_5`

Additional:

- `make test TEST=phase4_rampjump`
- `make test TEST=phase4_chicane_capture`

## Notes For Handoff

- Sector-entry snap authority is intentional; do not weaken it later in the
  name of continuity without checking deterministic replay quality first.
- Borderline authored sectors should fail early rather than quietly commit and
  create flaky downstream behavior.

## Post-Ship Follow-Up

- Endurance build passes should not run Stage B challenge-up even when their
  request text still includes `extreme`; endurance needs deterministic build
  cadence, not extra post-commit escalation laps.
- The long corner-owned editable shoulder is no longer required after sector
  entry snapping. Shrink it aggressively so fixed corner exits stop consuming a
  large slow-speed straight before handing off to the editable sector.
- Repair callout text must not re-trigger forever just because unrelated HUD
  attributes keep rendering while the same explanation/action strings remain in
  state.
- Endurance HUD copy should avoid exposing the internal `begin_loop` control
  token to the player-facing request banner.
- Normal startup should always come up on `Heuristic`; only explicit harness /
  automation boot commands should honor workspace LLM override attributes.
- Chicane geometry should move away from the current stitched three-turn path
  to a true smooth wave:
  - keep `amplitude` as wave height
  - keep `transition_length` as the stored field name, but reinterpret it as
    peak-to-peak spacing
  - preserve `corridor_width`
  - update scoring / proposer pressure so taller waves and tighter peak spacing
    are treated as harder, higher-value chicanes for endurance
  - builder / verifier guidance should follow one continuous centerline wave,
    not three independent eased offsets with a compressed middle reversal
