# Phase 8 Plan — Broadcast HUD UI

## Summary
- Build Phase 8 as a true screen-space HUD, not a world billboard: `ScreenGui` overlay, always-scripted verifier chase camera, and no requirement for the player to move their avatar.
- Visual direction is fixed to the chosen design: broadcast HUD, medium footprint, top status strip plus right-side telemetry rail, amber + steel palette, measured transitions, and a docked command bar.
- Keep world-space cues only as support: a subtle failure marker with a short trajectory tail, plus a brief success highlight on the committed sector.
- The observer goal stays exactly aligned with the PRD: someone should understand the propose → verify → repair → commit/revert loop without reading logs.

## Key Changes
- Add a server-owned replicated UI state object in `ReplicatedStorage`, named `AutoTrackUIState`, implemented as a `Folder` with scalar attributes:
  `phase`, `phase_label`, `busy`, `request_text`, `target_sector_id`, `target_mechanic`, `attempt_current`, `attempt_max`, `explanation`, `baseline_lap_time`, `last_lap_time`, `slowdown_ratio`, `final_status`, `error_text`, `log_1`, `log_2`, `log_3`, `log_4`.
- Add `ReplicatedStorage.AutoTrack_SubmitRequest` as a `RemoteEvent`. The client fires raw text; the server handles it with `task.spawn(JobRunner.submit(rawText))`. Immediate parse/busy rejection is surfaced through the shared replicated UI state instead of a blocking request/response API.
- Add a dedicated UI publisher/controller on the server side that translates job lifecycle events into replicated HUD state and marker/highlight lifecycles. `JobRunner` remains the execution source of truth; the publisher only mirrors state for UI.
- Build the HUD on the client from a new `StarterPlayerScripts` LocalScript that reads `AutoTrackUIState` and constructs the overlay at runtime using modules in `ReplicatedStorage.AutoTrackUI`. Do not add `BillboardGui` or require any in-world interaction surface.
- Keep the existing `TrackCamera.client.luau` model, but make the Phase 8 HUD assume watch-mode permanently: the camera remains scripted in idle and during runs.
- Insert pacing only around legibility states, not the physics lap. Keep the actual simulation runtime untouched; use `Constants.UI_PHASE_DELAY` only between visible non-lap phases and `Constants.UI_SUCCESS_DWELL` for post-commit success dwell.
- Implement HUD behavior as follows:
  top strip shows ready/error/phase/final status;
  right rail shows only baseline lap, last lap, and slowdown;
  bottom-docked command bar shows placeholder text, two short example prompts, and Enter plus a compact submit button;
  recent log shows the latest 4 notable events;
  explanation line shows only the latest short repair explanation.
- Implement world-space support cues as runtime-created Instances from `/src`, not via external MCP edits:
  failure marker persists across analysis/repair, includes a short recent trajectory tail, and clears on new job start or job completion;
  success highlight uses a subtle `Highlight` flash on the committed sector for `UI_SUCCESS_DWELL`.

## Public Interfaces
- New replicated runtime interface:
  `ReplicatedStorage.AutoTrackUIState` attributes listed above.
- New client-to-server input interface:
  `ReplicatedStorage.AutoTrack_SubmitRequest:FireServer(rawText)`.
- Existing `StatusPanel`, `StatsPanel`, `FailureMarker`, and `SuccessMarker` modules stay as the Phase 8 UI surface, but become real implementations rather than placeholders.
- `JobRunner` behavior is extended to publish UI state transitions and explanations, but its public job semantics do not change.
- Add `plans/phase8.md` before implementation begins, per repo policy.

## Test Plan
- Add `src/orchestrator/TestPhase8.luau`.
- Add suite wiring to:
  `src/orchestrator/TestDispatcher.luau`,
  `tools/test_bridge_config.json`,
  `Makefile`.
- Define `phase8_unit` with `skip_baseline` boot mode:
  assert `AutoTrackUIState` exists and boots into a ready idle state;
  assert baseline stat publication;
  assert phase-to-label mapping;
  assert recent-log capping to 4 lines;
  assert parse rejection and busy rejection update `error_text`, `phase_label`, and `busy` correctly.
- Define `phase8_integration` with `baseline` boot mode:
  submit a known successful request such as sector-3 `Chicane` and assert UI state transitions, attempt count, explanation propagation, last lap time update, slowdown update, final `committed` state, and success highlight cleanup;
  submit a known revert case such as sector-3 `CrestDip` and assert failure marker creation, persistence through repair phases, final `reverted` state, and cleanup on completion.
- Final validation should run through the maintained bridge path:
  `make phase8_unit`
  `make phase8_integration`
- After automated validation, do one manual Studio watch pass to confirm visual composition, readability, and transition timing; server-only tests can verify replicated state and marker objects, but not the final screen composition itself.

## Assumptions
- HUD state is global and shared across all observers in v1. No queueing, per-player private sessions, or moderator/operator roles are added.
- The status band is the only error surface; there are no toast alerts.
- The right rail stays disciplined to the PRD core stats only: baseline lap, last lap, slowdown.
- Final design defaults are locked:
  broadcast HUD, medium footprint, top + right layout, amber + steel palette, supportive world markers, always-visible ready HUD, current step plus short log, docked command bar, placeholder plus examples, Enter plus subtle button, measured motion, failure marker plus short tail, always-scripted chase camera.

## Camera Notes
- The current camera work remains part of Phase 8 because the HUD experience depends on it: this is a watch-mode product, not a player-driven avatar experience.
- The accepted direction is:
  scripted chase camera by default;
  obstacle-side camera for authored mechanic sectors;
  smooth pan out before the obstacle;
  smooth return after the obstacle;
  the car must remain the visual anchor at all times.
- Camera demo workflow:
  use the normal HUD command input with `/demo camera`.
  This starts an infinite loop with `RampJump` in sectors `3` and `7`.
  Submit `/demo camera` again to stop it.
  This exists specifically to evaluate camera timing and composition without changing normal boot flow.
  Slash commands are intentionally constrained:
  `/demo <name>` for demos and `/test <suite>` for direct in-session server-side suites.
  `/test <suite>` is convenience only and does not replace the maintained `make ...` flow, because it does not manage boot mode, baseline setup, or Studio restarts.
- Runtime camera state source:
  `UIState` publishes `current_sector_id` and per-sector metadata/active mechanic markers into `ReplicatedStorage.AutoTrackUIState`.
  The client camera reads only this replicated state plus live `VerifierCar` transforms.
- Current camera implementation lives in:
  `src/client/TrackCamera.client.luau`
  with tuning constants in
  `src/common/Constants.luau`.
- Important camera knobs:
  `CAMERA_CHASE_HEIGHT`
  `CAMERA_CHASE_DISTANCE`
  `CAMERA_SIDE_OFFSET`
  `CAMERA_SIDE_HEIGHT`
  `CAMERA_SIDE_BACK_OFFSET`
  `CAMERA_PREROLL_BACK_DISTANCE`
  `CAMERA_PREROLL_START_PROGRESS`
  `CAMERA_PREROLL_FULL_PROGRESS`
  `CAMERA_PREROLL_CURVE_POWER`
  `CAMERA_ALPHA_ENTER_SHARPNESS`
  `CAMERA_ALPHA_EXIT_SHARPNESS`
  `CAMERA_OBSTACLE_PREROLL_SECTORS`
- Current strategy:
  compute a chase pose each frame;
  compute a side pose each frame for the active or most-recent obstacle sector;
  drive a continuous `cameraBlendAlpha` toward desired side influence;
  compose the final camera from chase/side poses using that alpha.
  This is intentionally different from the earlier failed “swap target CFrames and lerp” approach.
- What the user liked:
  the current pan out into obstacle side view is considered good.
  The car staying in frame during preroll was a major requirement.
- What still remains only “good enough”:
  the pan back after the obstacle is acceptable but not perfect.
  There may still be residual discontinuity/jitter in the return around the following corner.
  If future work revisits this, do not casually destabilize the pan out to chase a perfect return.
- Dead ends already explored and not recommended:
  freezing the camera on a stale side pose then blending back to chase;
  recomputing a full-strength side shot after the car has clearly left the obstacle;
  binary obstacle-mode switching with `CurrentCamera.CFrame:Lerp(targetCFrame, ...)`;
  late-trigger preroll that begins only at or near obstacle entry;
  preroll that favors obstacle center over the car and temporarily loses the car in frame.
- If future agents need a cleaner return and the current blend still feels jittery:
  prefer an intentionally authored transition treatment such as a short fade, or a persistent camera rig with smoothed position/look-at state,
  rather than piling more ad hoc handoff branches onto `TrackCamera.client.luau`.
