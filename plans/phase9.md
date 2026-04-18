# Phase 9 — CrestDip: Real Repair Story

## Context

Phase 8 (broadcast HUD) is complete. All three v1 mechanics build and commit, but the agentic loop is not watchable yet: default proposals tend to either commit on the first lap or fail for uninteresting reasons. CrestDip is the worst case — it either commits out of the gate or reverts due to path-mismatch noise. Neither failure tells a story.

Phase 9 turns CrestDip into the flagship propose → fail → analyze → repair → commit demo. Scope is CrestDip only. RampJump and Chicane difficulty passes come later.

## Implementation

### 1. `src/mechanics/CrestDipPath.luau` (new)

Mirrors `ChicanePath.luau`. Exposes `buildLocalCenterlinePoints(heightOrDepth, sectorLength)` returning local Vector3 waypoints that sample the same cosine the builder uses (`y = h * 0.5 * (1 - cos(2π t))`), plus a final waypoint at `Z = STRAIGHT_LENGTH` to cover the flat runout.

### 2. `src/track/TrackGenerator.luau`

Import `CrestDipPath`. Add a CrestDip branch next to the Chicane branch in `buildStraightWaypoints`. Crucially: waypoint Y must incorporate the cosine-path Y, not the constant ride height. Inline a `ridePosCrest(local)` that lifts Y by `localY`.

### 3. `src/common/Types.luau`

Add `airtime_distance: number` to `RunMetrics`.

### 4. `src/common/Constants.luau`

- `CRESTDIP_MIN_VERTICAL_DISPLACEMENT`: 2 → 3
- `CRESTDIP_MIN_CURVATURE`: 0.02 → 0.006 (now actually consumed)
- `CRESTDIP_MAX_AIRTIME_DISTANCE`: new, 30 studs

### 5. `src/verifier/MetricCollector.luau`

Track the longest single airborne segment distance and add target-sector-local CrestDip telemetry:
- `target_vertical_displacement`
- `target_airborne`
- `target_air_distance`
- `target_reacquired`
- `target_airtime_distance`

This lets the verifier decide CrestDip runtime integrity at target-sector exit instead of deferring everything to lap end.

### 6. `src/integrity/CrestDipIntegrity.luau`

Split CrestDip integrity into:
- `preflight(state)` for authored-shape checks:
  - vertical displacement minimum
  - curvature minimum
- `evaluateRuntime(metrics)` for target-sector runtime checks:
  - runtime vertical displacement
  - airtime cap
  - reacquire before sector exit
- `evaluate(state, metrics)` as the combined fallback used for end-of-lap evaluation

### 7. `src/orchestrator/MinimalProposer.luau`

Expand CrestDip repair branches. Dispatch order (specific → general):
- `"airborne too long"` → height-=2, then sector_length+=10, then ingress brake
- `"curvature"` → height+=2, then sector_length-=10
- `"vertical displacement"` → height+=2
- `"reacquire"` → sector_length+=8, egress brake, height-=2
- `local_execution_failure` → unchanged softening fallback
- fallback → unchanged

Update `QUALIFIER_BIASES.CrestDip`: remove radius deltas (cosmetic), add a strong `really` bias, and tune `tall/steep/short` so they stack into an impossible geometry when combined.

### 8. `src/orchestrator/JobRunner.luau`

Add `/demo crest` as a slash command: submits `"add a crest in sector 3"` to exercise the repair chain end-to-end. Gate on CameraDemo not running and JobLock not held, consistent with existing `/demo camera`.

### 9. Tests

**New:** `src/orchestrator/TestPhase9.luau` — `runUnit()` + `runIntegration()`

Unit:
- `phase9_path_waypoints_follow_cosine` — peak Y equals height at z=L/2; ends land at 0
- `phase9_trackgenerator_routes_crestdip` — override state with CrestDip yields an elevated waypoint
- `phase9_preflight_curvature_hint` — static authored-shape failure is emitted before runtime
- `phase9_runtime_vertical_hint` — runtime-only failure is evaluable from target-sector telemetry
- `phase9_curvature_hint` — `CrestDipIntegrity.evaluate` on defaults returns curvature hint
- `phase9_airtime_hint` — synthetic metrics with airborne+long distance returns airtime hint
- `phase9_proposer_airtime_picks_height_reduction`
- `phase9_proposer_curvature_picks_height_increase`
- `phase9_proposer_dedup` — with last_action matching top candidate, fall through

Integration:
- `phase9_crest_commits_after_repair_chain` — `/demo crest` equivalent commits with ≥2 repair attempts
- `phase9_crest_reverts_on_impossible_qualifiers` — biased request exhausts repair budget

**Update:**
- `TestPhase4.runCrestDip` — soften fixtures to `h=4, L=50`; add `follows_curve` assertion
- `TestPhase6.runIntegration` — flip `job_reverts_on_exhaustion` to `job_commits_crest_after_repair_chain`; add separate revert assertion with biased qualifier request
- `TestPhase8.runIntegration` — the existing revert fixture using `add a crest in sector 3` now commits; switch to the biased-qualifier variant to preserve HUD-marker revert coverage

**Wire:**
- `TestDispatcher.luau` — `phase9`, `phase9_unit`, `phase9_integration`
- `tools/test_bridge_config.json` — `skip_baseline` for unit, `baseline` for integration and full
- `Makefile` — add to `.PHONY` and catch-all rule

## Target repair story (default request)

Request `"add a crest in sector 3"`, defaults `h=6, L=40`.

| Attempt | h | L | Curv h/L² | Peak slope | Airtime | Hint | Action |
|---|---|---|---|---|---|---|---|
| 0 | 6 | 40 | 0.00375 | 27° | grounded | curvature | `h += 2` |
| 1 | 8 | 40 | 0.005 | 32° | ~22 | curvature | `L -= 10` |
| 2 | 8 | 30 | 0.0089 | 42° | ~38 | airborne too long | `h -= 2` |
| 3 | 6 | 30 | 0.00667 | 32° | ~28 | — | **committed** |

Agent pulls height up for curvature, shortens `L` to satisfy curvature, then shorter `L` causes airtime failure, so it reverses the height bump. Multi-lever tradeoff visible in HUD log.

Importantly, the first two CrestDip failure classes no longer wait for lap end:
- static authored-shape failures are rejected in preflight before simulation
- target-sector runtime failures are rejected at sector exit or immediately on over-cap airtime
- only downstream safety still depends on the rest of the lap

Revert fixture: `"add a really tall steep short crest in sector 3"` → biases stack to impossible geometry; `local_execution_failure` softening branch churns without reaching a valid state within 5 attempts.

## Verification

Empirical prerequisite — before finalizing tuning values in Step 4, run one exploratory lap with `h=8, L=30` after Steps 1–3 land and verify `metrics.airborne` actually flips true on descent. If the waypoint follower pins the car too tightly to the cosine surface, the airtime cap becomes dead weight and we need to replace the metric with "peak vertical velocity" instead.

End-to-end:
- `make phase9_unit`, `make phase9_integration`
- `make phase4_crestdip`, `make phase6_integration`, `make phase8_integration` — updated assertions still pass
- Live Studio session: `/demo crest` → watch the 3-attempt repair chain in the HUD log

Observed result after implementation:
- `phase9_unit`: pass
- `phase9_integration`: pass
- `phase4_crestdip`: pass
- `phase6_integration`: pass
- `phase8_integration`: pass

## Risks

1. **Airtime metric may not fire with `CrestDipPath` active.** Biggest unknown. Fallback: switch to peak-vertical-velocity metric, same intent.
2. **Numeric tuning is iterative.** The 3-attempt story depends on exact constants. Expect one or two retune passes after live observation.
3. **Phase 8 test fixture flip.** Validate that the biased-qualifier request consistently reverts before shipping the Phase 8 update.
4. **`radius` is now fully cosmetic.** Keep as a lever for schema stability (Phase 7 LLMAdapter expects fixed lever lists); flag for future cleanup.
5. **Y-injection in TrackGenerator is easy to get wrong** by a factor of the `CAR_RIDE_Y` offset. The `phase9_trackgenerator_routes_crestdip` unit test catches this.

## Critical files

- `src/mechanics/CrestDipPath.luau` (new)
- `src/track/TrackGenerator.luau`
- `src/common/Types.luau`
- `src/common/Constants.luau`
- `src/common/LevelMappings.luau`
- `src/integrity/CrestDipIntegrity.luau`
- `src/verifier/MetricCollector.luau`
- `src/orchestrator/MinimalProposer.luau`
- `src/orchestrator/JobRunner.luau`
- `src/orchestrator/TestPhase9.luau` (new)
- `src/orchestrator/TestPhase4.luau`, `TestPhase6.luau`, `TestPhase8.luau`
- `src/orchestrator/TestDispatcher.luau`
- `tools/test_bridge_config.json`
- `Makefile`
- `plans/agent-handoff.md` (updated on phase completion)
