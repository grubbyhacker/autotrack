# Agent Handoff

## Phase completion status

| Phase | Status |
|-------|--------|
| 1 | Complete — track generator, fixed corners, numbered editable straights, job lock, baseline lap |
| 2 | Complete — sector registry, serializer, applier, rollback |
| 3 | Complete — verifier car, semi-rail controller, failure detection, reacquire |
| 4 | Complete — RampJump, Chicane, CrestDip builders + PadBuilder |
| 4.5 | Complete — corner arc paths + speed reduction |
| 5 | Complete — integrity evaluators + FailurePacket wiring |
| 6 | Complete — CI orchestrator state machine (no LLM) |
| 7 | Complete — LLM adapter boundary + swappable mock/stub backend |
| Local CLI | Complete — terminal Studio bridge + `make` targets |
| 8 | Complete — broadcast HUD + replicated UI state + live markers |
| 9 | Complete — CrestDip path + early integrity gating + repair-story tuning |
| 10 | Complete — RampJump/Chicane rigor + persistent pad speed semantics |
| 11 | Complete — ChallengeScore telemetry, Stage B challenge-up, `/demo maximize`, pad tier expansion |
| 12 | Complete — visual readability pass: sector shells, corner roads, F1 verifier shell, ramp supports |
| 13 | Complete — real LLM via OpenRouter, `LLMConfig`, multi-turn repair history, HUD model selector |
| 14 | Complete — endurance mode orchestration, continuous loop, hotfix terminal HUD |
| 14.5 | Complete — orchestrator memory, formal endurance objective, HUD decision telemetry, dedicated `phase14_5` gate |
| 14 Retune | Complete — straight-entry recovery plus denser flat guidance restored CrestDip/endurance reliability |
| 15 | Complete — RampJump continuous entry arc, shared ramp profile, dedicated `phase15` gate |
| 16 | Complete — RampJump playability retune, `/demo rampitup`, full-lap ramp stabilization, dedicated `phase16` gate |

## Current state

- `phase14.5`, `phase15`, and `phase16` are landed and committed.
- Recent UI cleanup changed HUD semantics materially:
  - repair attempts now live in a dedicated top-edge `REPAIR MODE | ATTEMPT x/y` banner and should only show when `attempt_current > 0`
  - endurance and hotfix are independent left-side badges above `Live`, not overloaded into repair UI
  - LLM backend/model failures now surface as an amber warning strip above the `LLM` panel, not in the old attempt cluster
  - repair explanation/action copy is now a transient callout below the top ribbon and must not be fed from endurance/orchestrator telemetry each render
- Demo/HUD commands in active use:
  - `/demo camera`, `/demo rampitup`, `/demo repair`, `/demo llmerror`, `/demo ui-hotfix`
- Endurance policy/objective work lives in:
  - `src/orchestrator/OrchestratorAgent.luau`
  - `src/orchestrator/MinimalOrchestrator.luau`
  - `src/orchestrator/EnduranceObjective.luau`
  - `src/agent/OrchestratorPromptBuilder.luau`
  - `src/orchestrator/UIState.luau`
  - `src/client/HUD.client.luau`
  - `src/ui/StatusPanel.luau`
- RampJump geometry/playability work lives in:
  - `src/mechanics/RampJumpBuilder.luau`
  - `src/mechanics/RampJumpPath.luau`
  - `src/mechanics/RampJumpTuner.luau`
  - `src/integrity/RampJumpIntegrity.luau`
  - `src/verifier/VerifierController.luau`
  - `src/orchestrator/CameraDemo.luau`
- Track visual cleanup changed the rendering strategy:
  - the old per-sector shell underlay was replaced with a shared track foundation in `TrackVisuals.renderTrackFoundation`
  - corner visuals now use denser visual-only path sampling than the verifier path
  - chicanes now render hidden segmented collision plus a denser smooth visual overlay; when retuning chicane visuals, keep the collision path and visual path conceptually separate

## Current reliability posture

- Working objective is still demo reliability over pure physics fidelity.
- Target-sector entry normalization and recovery assists exist and are mechanic-specific.
- Non-corner straights currently use stronger yaw/roll damping and forward-heading pinning than corners.
- Corner-exit acceleration is now heading-gated: on the exit shoulder and first `0.15` of the following straight, target speed stays pinned until forward alignment exceeds `0.992`, which removes the visible slide-before-rotate handoff from S1 into S2.
- `VerifierController.runLap` now explicitly settles the verifier at lap completion (zero linear/angular velocity, align to final heading) so completed laps do not drift or steer off the track after control teardown.
- RampJump full-lap stability depends on both geometry and verifier behavior:
  - calmer entry normalization
  - airborne heading freeze to ramp/path heading
  - post-landing / post-exit recovery help
  - conservative `/demo rampitup` presets in sectors `3` and `8`

## Maintained verification snapshot

- `make test TEST=phase14_5`
- `make test TEST=phase14_unit`
- `make test TEST=phase14_integration`
- `make test TEST=phase14_crestdip_pair`
- `make test TEST=phase14_sector2_debug`
- `make test TEST=phase15`
- `make test TEST=phase16`
- `make test TEST=phase4_rampjump`
- `make test TEST=phase4_5`
- `make phase4_5_geometry`
- `make phase4_5_speed`
- `make test TEST=phase5_unit`
- `make test TEST=phase9_unit`
- `make test TEST=phase3`

## Recommended next focus

- Keep `phase14_5` in the fast gate set whenever endurance-policy or HUD-decision work changes.
- Keep `phase14_integration` as the real acceptance gate for endurance retunes.
- When verifier or RampJump behavior changes, check the actual `/demo rampitup` full-lap path in addition to the narrow suites.
- When corner-exit feel changes, recheck `phase4_5_speed`; if the car starts sliding again, inspect heading-gated acceleration before retuning raw accel rates.
- If CrestDip reliability regresses again, inspect straight lead-in speed and waypoint density before expanding mechanic-specific repair logic.
- For future track-visual work, avoid mixing collision/verifier path, smooth visual overlay, and edge piping in one tweak; visual-only fixes are safer when those stay separate.
- Two failed visual approaches from this session should not be repeated casually:
  - trimming corner visual shoulders to zero produced V-shaped corners
  - forcing aggressive endpoint trimming/overlap on visible top ribbons exposed spoke-like seams or z-fighting
