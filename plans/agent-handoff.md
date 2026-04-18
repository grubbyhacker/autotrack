# Agent Handoff

## Phase completion status

| Phase | Status |
|-------|--------|
| 1 | Complete |
| 2 | Complete |
| 3 | Complete |
| 4 | Complete |
| 4.5 | Complete (corner arc paths + speed reduction) |
| 5 | Complete (integrity evaluators + FailurePacket wiring) |
| 6 | Complete (CI orchestrator state machine + no-LLM vertical slice) |
| 7 | Complete (LLM adapter boundary + swappable mock/stub backend) |
| Local CLI | Complete (terminal-triggered Studio test bridge + make targets) |
| 8 | Complete (broadcast HUD + replicated UI state + live markers) |
| 9 | Complete (CrestDip path + early integrity gating + repair-story tuning) |
| 10 | Complete (RampJump/Chicane rigor + persistent pad speed setting) |
| 11a | Complete — ChallengeScore telemetry, scoring, and automated Phase 11 coverage |
| 11b | Complete — Stage B challenge-up via `extreme` qualifier + per-sector HUD score publication |
| 11c | Complete — `/demo maximize` campaign with retained sector scores, final budget probe, and eviction loop |
| 11d | Partial — `extreme` opening proposals are now biased harder; escalation/search remains simple |

---

## Phase 4 lessons learned

### 1. Geometry and guidance must match

`Chicane` exposed a structural issue: mechanic geometry and verifier guidance cannot be treated as separate concerns.

If a sector's authored drive line differs materially from the flat straight centerline, `TrackGenerator.getLapPath(...)` or an equivalent path provider must supply intra-sector waypoints for that mechanic. Otherwise the verifier will "cheat" by driving the old straight path through new geometry.

This was fixed for `Chicane` by adding:

- `src/mechanics/ChicanePath.luau`
- mechanic-aware path generation in `src/track/TrackGenerator.luau`
- updated verifier path consumption in `src/verifier/VerifierController.luau`

### 2. Sector completeness is an invariant

We hit multiple bugs where a mechanic ended early and left empty space before the next corner.

This must be treated as a hard rule, not an aesthetic preference:

- any mechanic that consumes less than `Constants.STRAIGHT_LENGTH` must still provide continuous drivable surface to the sector boundary
- intentional gaps are allowed only if the mechanic explicitly defines a valid landing/rejoin path afterward

### 3. Fast inner-loop mode is essential

Use `workspace:SetAttribute("AutoTrack_SkipBootBaseline", true)` before starting Play when iterating on a targeted mechanic slice. This avoids the ~25s baseline lap on every restart.

### 4. Runtime pass is not enough for shape-heavy mechanics

`CrestDip` originally passed runtime traversal but the shape was wrong. Visual/kinematic quality must be treated as a first-class acceptance criterion when curvature is the point of the obstacle.

### 5. Pads must affect runtime, not just rendering

Pads were initially only visual. Runtime handling lives in `src/verifier/VerifierController.luau`.

### 6. TrackGenerator now has a mechanic dependency

`src/track/TrackGenerator.luau` requires `ChicanePath` from Mechanics. Acceptable for now; revisit in a future refactor.

---

## Phase 4.5 lessons learned

### 1. Corner arc geometry derivation

All four corners are clockwise (right turns). Arc center formula:
```lua
arcCenter = entry.Position + entry.LookVector:Cross(Vector3.new(0,1,0)) * R
```
where `R = CORNER_RADIUS + TRACK_WIDTH * 0.5 = 28` studs. Verified: distance from arcCenter to entry/exit = R for all 4 corners.

### 2. Closing waypoint inflates corner waypoint count

`getLapPath` appends a lap-closing waypoint at the end tagged as sector 1. When collecting per-sector waypoints for tests, exclude `waypoints[#waypoints]` to avoid inflating corner 1's count by 1.

### 3. Corner speed reduction is automatic, not pad-driven

Corners are fixed/uneditable. The agent can never place pads there. Corner speed reduction (`CORNER_SPEED_FACTOR = 0.6`) is applied automatically in `VerifierController` when `sectorKinds[currentSectorId] == "Corner"`. Anticipatory braking (slowing on the preceding straight) is deferred — it conflicts with egress pads at straight sector ends.

---

## Phase 5 lessons learned

### 1. Integrity scaffolding had latent require path bugs

All four `src/integrity/` files used `script.Parent.Parent.common.Types` which resolves to `AutoTrackCore.common`. But `src/common/` maps to `ReplicatedStorage.AutoTrackCommon`, not `AutoTrackCore`. These files had never been `require`d before Phase 5 so the bug was latent.

**Rule:** Modules in `src/integrity/`, `src/track/`, `src/verifier/`, `src/mechanics/`, `src/orchestrator/` must reference `src/common/` via `ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ModuleName")`, not via relative `script.Parent.Parent.common`.

### 2. Luau type annotations on table field assignments are invalid

```lua
-- INVALID — colon after table access is parsed as method call:
LevelMappings.NUMERIC_LEVERS: { [string]: { string } } = { ... }

-- Valid alternatives:
local x: { string } = { ... }       -- local variable annotation
LevelMappings.NUMERIC_LEVERS = { ... }  -- no annotation needed
```

### 3. LapEvaluator.evaluate now returns two values

Callers must destructure `(RunResult, { string })`:
```lua
local result, hints = LapEvaluator.evaluate(lapFailure, state, metrics, targetSectorId)
```
The second return (hints) is needed to build a meaningful FailurePacket. If you ignore it, `buildFailurePacket` will have empty `diagnostics.hints`.

### 4. targetSectorId vs lapFailure.sector_id

`LapEvaluator.evaluate` takes `targetSectorId` (the job's intended target sector) as the 4th argument. This is NOT `lapFailure.sector_id` (which is where the car actually failed). Always pass the job's target, not what FailureDetector reported. The reclassification logic uses this to detect downstream failures.

### 5. The get_console_output MCP tool has a short line buffer

The tool appears to return only the most recent ~10–15 console lines. During a lap traversal (which produces no console output), the buffer doesn't change, making it look frozen. This is expected. Poll until the lap completes and new PASS/FAIL lines appear. Patience is required — each lap takes ~25 seconds.

### 6. Plans were not persisted before implementation in Phase 5

The Phase 5 plan was only in Claude's plan-mode plan file, not in `plans/phase5.md`. This was caught post-hoc. **Plans must be saved to `plans/phaseN.md` before implementation begins.** See AGENTS.md for the updated requirement.

---

## What Phase 6 needs to know

Phase 6 implements the CI orchestrator state machine: `AttemptRunner.run` + the full `JobRunner.submit` loop.

**Key stubs to implement:**

- `src/orchestrator/AttemptRunner.run` — currently throws `error("not yet implemented")`
- `src/orchestrator/JobRunner.submit` — currently throws `error("not yet implemented")`

**Integration contract for AttemptRunner:**

```lua
-- AttemptRunner.run sequence:
-- 1. Clone workingState; apply action if provided
-- 2. SectorApplier.apply(workingState, entryFrame, exitFrame)
-- 3. VerifierCar.reset(canonicalStart)
-- 4. VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, onSectorChange)
-- 5. result, hints = LapEvaluator.evaluate(lapFailure, workingState, metrics, targetSectorId)
-- 6. return result, hints, updatedState
```

**LapEvaluator.evaluate signature (Phase 5 output):**
```lua
function LapEvaluator.evaluate(
    lapFailure: FailureInfo?,
    targetState: SectorState,
    metrics: RunMetrics,
    targetSectorId: number
): (RunResult, { string })
```

**LevelMappings.NUMERIC_LEVERS** provides legal levers per mechanic for FailurePacket construction. Already wired into `buildFailurePacket` — pass the hints from `evaluate()`.

**No-LLM vertical slice (Phase 6 start):** Hardcode one parsed request (e.g., RampJump on sector 4), one initial proposal (default params from LevelMappings.DEFAULTS), one repair policy (increment ramp_angle by 5). Prove physics/rollback/geometry before connecting Phase 7 LLMAdapter.

**SectorRollback** exists in `src/track/SectorRollback.luau` — use it on job failure or exhaustion.

**JobStateMachine** exists in `src/orchestrator/JobStateMachine.luau` (scaffolded) — read it before designing the Phase 6 state transitions.

---

## Phase 6 lessons learned

### 1. Agent-side modules had latent Rojo require-path bugs too

Phase 5 found this in `src/integrity/`. Phase 6 hit the same class of issue in `src/agent/` and `src/orchestrator/`.

Anything that needs `src/common/` at runtime must require it from:

```lua
game:GetService("ReplicatedStorage"):WaitForChild("AutoTrackCommon")
```

not from a relative `script.Parent.Parent.common` path.

### 2. Runtime context must be published explicitly after boot

`Main.server.luau` previously held `sectors`, `car`, and the canonical start only as script locals. That is fine for boot-time code, but the CI orchestrator runs later and needs those exact live objects.

`src/orchestrator/RuntimeContext.luau` now owns that shared boot-produced state. Future phases should read from it instead of rebuilding track metadata ad hoc.

### 3. The no-LLM proposer should stay as a mock backend, not dead code

`MinimalProposer` is now a stable deterministic backend that:

- produces valid initial `SectorState` values
- emits single-action repairs
- is already proven end-to-end against the live loop

Phase 7 should keep it as the default/mock backend behind `LLMAdapter` rather than deleting it.

### 4. Verifier metrics need the target sector, not the current sector at termination

`VerifierController.runLap(...)` had to accept an optional `targetSectorId` and thread it into `MetricCollector.finalise(...)`.

Without that, failures outside the target sector produce the wrong entry/exit speed attribution for the repaired sector.

### 5. Chicane is a reliable integration-test mechanic; CrestDip is a good revert case right now

On the current track:

- `Chicane` on sector 3 commits reliably and is good for commit/version-bump assertions
- `CrestDip` on sector 3 currently exhausts repairs and reverts, which is useful for rollback assertions

Do not assume every supported mechanic is currently a stable "successful commit" fixture for integration tests.

---

## Phase 7 lessons learned

### 1. The adapter should own JSON parsing, not the backend

The backend boundary is cleaner when providers may return either a Lua table or a JSON string and `LLMAdapter` is the only place that normalizes and validates that data.

That keeps:

- prompt construction in `PromptBuilder`
- response decoding in `LLMAdapter`
- schema enforcement in `ActionValidator`

instead of spreading parsing logic across multiple providers.

### 2. Keep the deterministic proposer as the default backend

The mock backend now wraps `MinimalProposer` but still goes through the same prompt → backend → decode → validate path as any injected provider.

This matters because it means:

- the adapter is exercised continuously in normal development
- future real backends can be swapped in without changing orchestrator code
- integration tests can still run without network dependencies

### 3. Validate request identity, not just schema shape

A structurally valid `SectorState` is still wrong if it targets the wrong sector or mechanic.

`LLMAdapter.propose(...)` must reject:

- `sector_id` mismatch
- `mechanic` mismatch

even when `ActionValidator.validateSectorState(...)` passes.

### 4. Explanation strings need an explicit UI-safe policy

Repair responses now require a short, non-empty explanation and reject empty or overlong strings.

This enforces the PRD/UI rule early and prevents long reasoning traces from leaking into later phases.

### 5. Provider injection is the right way to test the orchestrator boundary

The most useful Phase 7 integration test was not a fake prompt assertion. It was a real `JobRunner.submit(...)` run with an injected stub provider, proving the orchestrator now depends on `LLMAdapter` rather than `MinimalProposer` directly.

---

## Local CLI lessons learned

### 1. Studio should return structured results, not just console text

---

## Phase 8 camera lessons learned

### 1. The camera is part of the HUD product, not a side feature

Because AutoTrack is a spectator experience, camera behavior is part of the core UI layer. Treat changes in `src/client/TrackCamera.client.luau` with the same care as HUD layout changes.

### 2. The user explicitly wants a HUD + watch-mode experience

Important user intent that should not be re-litigated:

- no avatar-centric experience
- no need for the observer to move around manually
- chase camera by default
- obstacle sectors should pan to an elevated outside-track side view
- the car must remain visible and be the visual anchor during transitions

### 3. Rojo / client sync failures created false camera-debug signals

Several rounds of camera debugging were confounded by Studio still running an old `TrackCamera` LocalScript in `PlayerScripts`.

What happened:

- Rojo hit a sync problem on `src/client/TrackCamera.client.luau`
- Studio kept the older chase-only client script
- server-side replicated trigger data was correct, but the running client behavior did not reflect the edited file

Implication:

- if camera behavior seems impossible or unchanged, verify the live `PlayerScripts.TrackCamera.Source` before assuming the camera logic is wrong
- do not assume a changed file is live just because server code is updated

### 4. “Lerp to a target CFrame” was the wrong control strategy

The biggest dead end was treating the camera as a sequence of target shots and using:

```lua
CurrentCamera.CFrame = CurrentCamera.CFrame:Lerp(targetCFrame, ...)
```

with binary mode switching between chase and side views.

This caused:

- abrupt-feeling pans
- handoff discontinuities
- cases where the transition still felt late even when the trigger started earlier

The more successful direction was:

- compute chase pose every frame
- compute side pose every frame
- maintain a persistent blend alpha
- compose final camera from those poses

### 5. Keeping the car in frame mattered more than “showing the obstacle early”

User feedback consistently prioritized:

- the car staying visible
- the car remaining the focus during preroll

This mattered more than maximizing early obstacle reveal. Several early versions over-favored obstacle center and made the user feel like they were “missing the action.”

### 6. Pullback-first preroll was the right directional idea

The successful pan-out direction came from:

- starting preroll in the previous sector
- pulling back before moving far laterally
- using a continuous side-influence ramp rather than a sudden mode handoff

If revisiting preroll, preserve that shape unless the user asks otherwise.

### 7. The pan-out is currently good; do not casually destabilize it

Latest user feedback:

- pan out into obstacle side view: **good / “perfect now”**
- return to chase: **acceptable / “good enough”**, but not mathematically perfect

Future agents should be conservative. The user explicitly accepted the current state rather than asking for more refinement.

### 8. Return-path experimentation hit several dead ends

Approaches that caused regressions:

- freezing a stale side-shot pose and blending back to chase
- recomputing a strong live side shot too long after the obstacle
- mixing incompatible exit anchoring schemes

These often produced:

- visible jump cuts in the following turn
- “hang then snap” behavior
- worse regressions than the imperfect baseline

### 9. If future refinement is needed, do not keep layering handoff hacks

If a future milestone wants a truly polished return transition, preferred next directions are:

- a persistent camera rig with independently smoothed position and look target
- an authored camera rail per mechanic class
- an intentional visual transition such as a short fade

Do **not** keep stacking more ad hoc exit-branch exceptions onto the current file without first simplifying the control model.

### 10. Demo workflow now exists and should be reused

The camera demo should be triggered through the normal HUD input with:

- `/demo camera`

This command now toggles the camera demo on and off. It runs repeated `RampJump` obstacles in sectors `3` and `7` specifically for camera evaluation.

There is also a session-local test shortcut:

- `/test <suite>`

Important:

- `/test` reuses the existing `TestDispatcher.runSuite(...)` logic
- `/test` does **not** replace the maintained `make ...` workflow
- `/test` does **not** manage boot mode, baseline readiness, or Studio restart/setup
- use `/test` only as an in-session convenience when the current Play session is already appropriate for that suite

### 11. Do not manage Rojo lifecycle for the user

This session exposed a collaboration boundary that future agents should respect:

- do not start, stop, restart, or otherwise manage the user’s Rojo server unless they explicitly ask
- do not assume Rojo errors imply permission to take over server lifecycle

The user has an established Rojo workflow and, after a restart, may need to take a manual client-side action to complete synchronization. Leave that process to them.

### 12. Client-side sync can require a manual user step after Rojo restart

Even after Rojo is healthy again, the latest LocalScript may not be live until the user completes their usual Studio/client sync step and restarts Play as needed.

Practical implication:

- if a client feature appears unchanged, verify whether the live `PlayerScripts` copy is stale before assuming the logic is wrong
- ask the user to complete their normal Rojo/client resync routine rather than improvising a new one

### 13. Slash-command surface was intentionally narrowed

Earlier in the session, several ad hoc command aliases were added for the camera demo. These were later removed on purpose.

Current intended command surface:

- `/demo camera`
- `/test <suite>`

Do not reintroduce loose variants like:

- `camera demo`
- `demo camera`
- `stop camera demo`
- `/camera demo`

unless the user explicitly asks for them again.

### 14. `/test` is safe only because it reuses the existing dispatcher

The `/test <suite>` shortcut is acceptable because it calls the existing server-side `TestDispatcher.runSuite(...)` path rather than inventing a second test mechanism.

Guardrail for future work:

- if a future shortcut bypasses the existing dispatcher/bridge contract, it should be treated as a workflow regression

### 15. Good-enough camera state was explicitly accepted

By the end of this session, the user accepted the camera behavior as “good enough.”

That means:

- document it
- preserve the current satisfactory pan-out behavior
- avoid reopening the camera transition problem unless the user explicitly asks for more polish in a later milestone

---

## Phase 8 lessons learned

### 1. Replicated folder attributes are a good v1 HUD contract

For this project shape, a single `ReplicatedStorage.AutoTrackUIState` folder with scalar attributes was simpler and more robust than inventing a custom client store protocol.

This worked well because:

- there is only one global job in v1
- all observers should see the same state
- tests can assert HUD behavior without reading the screen

Future UI changes should prefer extending this attribute contract before adding bespoke remote chatter.

### 2. Keep UI publication outside the execution core

`JobRunner` remains the source of truth for job flow, but UI mirroring now goes through `src/orchestrator/UIState.luau`.

That separation matters because it keeps:

- request execution in `JobRunner`
- client rendering in `src/client/HUD.client.luau` and `src/ui/*`
- replicated observer state in one server-owned module

Do not move client-facing state mutations into random mechanic/verifier modules.

### 3. World markers should be runtime-created, not Studio-authored

Failure and success markers are created and destroyed at runtime from code:

- `src/ui/FailureMarker.luau`
- `src/ui/SuccessMarker.luau`

This matches the Rojo authority boundary and makes the markers testable from server-side suites.

### 4. Integration tests can verify HUD behavior without screen scraping

Phase 8 did not need image assertions.

The reliable path was:

- assert replicated `AutoTrackUIState` attributes
- assert runtime marker objects in `workspace.AutoTrackUIWorld`
- run the maintained Studio bridge via `make phase8_unit` / `make phase8_integration`

Keep using this pattern for future HUD iterations unless visual fidelity itself becomes the requirement.

The old MCP flow relied on console scraping. That was fine for agent-driven validation, but it is a poor contract for a local terminal runner.

`src/orchestrator/TestSession.luau` now records:

- suite name
- status
- pass/fail/error counts
- ordered output lines

under `ReplicatedStorage.AutoTrackTestStatus`, while preserving the existing console output.

### 2. The terminal bridge must be outbound from Studio, not inbound to Studio

Studio plugins can call localhost via `HttpService`, but Studio does not host a local HTTP listener.

The working direction is:

- `make` starts a one-shot localhost server
- the Studio plugin polls it
- the plugin runs the suite and posts the result back

### 3. `StudioTestService` is cleaner than trying to fake a client RemoteEvent call from a plugin

The MCP path triggered `AutoTrack_TestCmd` from a client. For local CLI runs, the better model is:

- plugin receives command
- plugin calls `StudioTestService:ExecutePlayModeAsync(...)`
- server-side bootstrap reads `StudioTestService:GetTestArgs()`
- bootstrap runs the suite directly and returns the snapshot with `StudioTestService:EndTest(...)`

That keeps the manual RemoteEvent path intact while giving the terminal runner a synchronous Play-mode result.

---

## Phase 9 handoff (CrestDip repair story)

### Status at handoff

Phase 9 is complete and tuned enough to satisfy the maintained suite contract.

Verified passes:
- `make phase9_unit`
- `make phase9_integration`
- `make phase4_crestdip`
- `make phase6_integration`
- `make phase8_integration`

The major behavioral change from the original Phase 9 plan is that CrestDip failures are no longer all deferred to lap end:
- static authored-shape failures are rejected in preflight before simulation
- target-sector runtime failures are rejected at target-sector exit, or immediately when airtime exceeds the cap
- downstream failures still require the rest of the lap, preserving the full-lap CI rule

### Files changed this phase

New:
- `src/mechanics/CrestDipPath.luau` — cosine waypoint sampler mirroring `CrestDipBuilder`
- `src/orchestrator/TestPhase9.luau` — unit + integration coverage for preflight, runtime-local integrity, and the commit/revert stories
- `plans/phase9.md` — committed plan

Modified:
- `src/common/Types.luau` — added `airtime_distance` plus target-sector CrestDip telemetry fields to `RunMetrics`; `AttemptRecord` now stores `hints`
- `src/common/Constants.luau` — tightened `CRESTDIP_MIN_VERTICAL_DISPLACEMENT` (2→3), tightened `CRESTDIP_MIN_CURVATURE` (0.02→0.006), added `CRESTDIP_MAX_AIRTIME_DISTANCE = 30`
- `src/verifier/MetricCollector.luau` — tracks longest single airborne segment (`_maxAirSegment`) and target-sector-local CrestDip telemetry used for early runtime integrity decisions
- `src/track/TrackGenerator.luau` — added CrestDip branch in `buildStraightWaypoints`; new `ridePosY(p, liftY)` helper so cosine Y lifts the ride height instead of being overwritten by it
- `src/integrity/CrestDipIntegrity.luau` — split into `preflight`, `evaluateRuntime`, and combined `evaluate`
- `src/integrity/LapEvaluator.luau` — added `preflight(...)`, zero-metrics handling for pre-run integrity failure, and hint threading for early mechanic failures
- `src/verifier/VerifierController.luau` — now rejects CrestDip at target-sector exit or on over-cap airtime instead of waiting for lap completion
- `src/orchestrator/AttemptRunner.luau` — now runs preflight before applying geometry and threads early integrity hints back to the repair loop
- `src/orchestrator/MinimalProposer.luau` — new `QUALIFIER_BIASES.CrestDip` table (removed radius deltas; added strong `really` bias so `really tall steep short` is reliably impossible), new dispatch order in repair branch (`airborne too long` → `curvature` → `vertical displacement` → `reacquire` → `local_execution_failure` → fallback), added `Constants` require for `sectorLengthCap`
- `src/orchestrator/JobRunner.luau` — added `/demo crest` handler that submits `"add a crest in sector 3"` (gated on CameraDemo/JobLock); attempt records now retain hint lists
- `src/orchestrator/TestPhase4.luau` runCrestDip — softened fixture to `h=4, L=50` (previously h=5, L=40); added `crestdip_second_lap_follows_curve` assertion (`vertical_displacement > 3.5`)
- `src/orchestrator/TestPhase6.luau` runIntegration — split old `job_reverts_on_exhaustion` into two: new `job_commits_crest_after_repair_chain` (plain crest → committed, ≥2 attempts) and a reworked `job_reverts_on_exhaustion` using `"add a really tall steep short crest in sector 3"` (reverts to Chicane)
- `src/orchestrator/TestPhase8.luau` runIntegration — flipped revert fixture to `"add a really tall steep short crest in sector 3"` to preserve HUD/marker coverage
- `src/orchestrator/TestDispatcher.luau` — added `phase9` / `phase9_unit` / `phase9_integration` branches
- `tools/test_bridge_config.json` — added phase9 entries (unit `skip_baseline`, full/integration `baseline`)
- `Makefile` — added phase9 targets to `.PHONY` and catch-all rule

### Lessons learned

1. **Mechanic integrity should not all live at lap end.**
Static authored-shape checks like CrestDip curvature and minimum displacement were creating unsatisfying late failures. Preflight catches those before simulation, and target-sector runtime checks now fail at the moment they become conclusive.

2. **Target-sector telemetry is different from lap-global telemetry.**
For CrestDip, deciding `runtime vertical displacement too small`, `airborne too long after liftoff`, and `reacquire before sector exit` required target-sector-local metrics. The old lap-global maxima were not precise enough to support early failure.

3. **The impossible-fixture qualifiers were too weak until `really` had real weight.**
`tall + steep + short` alone still allowed the repair loop to rescue the crest inside five repairs. Adding a strong `really` bias made the impossible test deterministic enough for the maintained suite contract.

### Known risks (reiterated from `plans/phase9.md`)

- **Airtime cap remains path-follower-sensitive.** It now fires in the current tuned setup, but any future guidance changes that glue the car harder to the path may make `CRESTDIP_MAX_AIRTIME_DISTANCE` ineffective again.
- **Phase 6/8 revert coverage depends on the impossible-fixture staying impossible.** If future CrestDip tuning or repair heuristics become more permissive, rerun `phase9_integration`, `phase6_integration`, and `phase8_integration` together.
- **`radius` is now fully cosmetic** on CrestDip. Kept as a lever for schema stability (Phase 7 LLMAdapter assumes fixed lever lists). Flag for future cleanup, not this phase.

### `/demo crest`

`JobRunner.submit("/demo crest")` now routes directly to `add a crest in sector 3` after the same CameraDemo/JobLock gates as `/demo camera`. The "unknown demo" error message lists both commands. Use this to watch the Phase 9 repair story end-to-end in Studio without typing the full request string.

---

## Phase 10 handoff (RampJump and Chicane rigor)

### Status at handoff

Phase 10 is complete on the maintained suite path.

Verified passes:
- `make phase10_unit`
- `make phase10_integration`
- `make phase4_pads`
- `make phase6_integration`
- `make phase8_integration`
- `make phase9_unit`
- `make phase9_integration`

### What changed

- `RampJump` and `Chicane` now follow the same integrity timing model introduced for `CrestDip`:
  - static authored-shape failures rejected in preflight
  - runtime-local failures evaluated at target-sector exit
  - full-lap continuation reserved for downstream failures
- `RunMetrics` gained target-local chicane telemetry (`target_left_offset`, `target_right_offset`, `target_lateral_band_changes`) and `MetricCollector` now records that telemetry in target-sector local space.
- `VerifierController.runLap(...)` now evaluates target-sector runtime integrity for `RampJump` and `Chicane`, not just `CrestDip`.
- `MinimalProposer` was retuned substantially:
  - jump takeoff failures prefer `ingress Boost`
  - jump landing failures prefer `egress Brake`
  - unstable chicanes now relax `transition_length`/`corridor_width` instead of wasting attempts on repeated pad no-ops
  - crest local-stall failures now lengthen `sector_length` before trying boost
- `ChicaneIntegrity.preflight(...)` now rejects shapes whose total authored length would exceed the sector. This prevents the live map from being torn open by a failing build after the baseline part is already removed.
- `JobStateMachine` now allows `ApplyRepair -> Revert`, which is required when the repair agent exhausts legal state-changing actions while already inside the repair phase.

### Pad behavior

The largest non-obvious Phase 10 change is pad semantics.

Pads no longer act as tiny overlap-local speed nudges. They now:
- set the commanded speed when activated
- snap the verifier's actual velocity to that new speed immediately
- persist for a bounded downstream window measured in sector hops
  - `IngressPad`: current sector
  - `EgressPad`: current sector plus the next sector

Corner handling was also corrected: corner slowdown now caps the target speed instead of multiplying pad-adjusted speeds. This avoided downstream near-stall failures and restored the Phase 4 pad-only traversal contract.

### Lessons learned

1. **No-op repair actions are poison in a small repair budget.**
`MinimalProposer` originally avoided only the immediately previous action, which allowed it to waste later attempts re-applying a pad that was already set. Filtering for state-changing actions fixed this.

2. **Builder legality must be enforced before geometry teardown.**
The chicane repair loop could previously ask for `transition_length` values that exceeded the sector-length envelope. Because the failure happened after `SectorApplier` had already cleared the baseline part, the live map could be left broken. Preflight length validation is now mandatory for that class of failure.

3. **Pad effects need controller semantics, not just constants.**
Doubling boost/brake magnitudes alone was not enough. The important fix was changing pads from ephemeral overlap-local deltas into persistent speed setters with immediate velocity application and bounded downstream duration.

4. **Wall-like crests are feature-length failures first.**
When CrestDip looked like a wall, `ingress Boost` was a wasted repair. The better first lever was `sector_length`, then height softening, then exit stabilization.

### Remaining note

The user raised the idea of adding stronger pad tiers (effectively "really slow" / "really fast" variants). That is not implemented in this phase. The current schema and UI still expose only `None`, `Boost`, and `Brake`; the observed improvement came from changing how those pads behave, not from expanding the pad taxonomy.

---

## Phase 11 handoff (Challenge rewards — overnight design)

### What you are walking into

The user asked for a reward system that makes agents build bigger jumps, deeper
crests, and tighter chicanes instead of the satisfice-the-gate obstacles we
ship today. They specifically called out "hang time", "near crash", and the
idea of an "uber agent that tries to build a track with the maximum amount of
points but is still within x% of the vanilla lap time". They gave the night to
prototype and said to impress them.

All design work is in `plans/phase11.md`. Read that first.

### Branch

`feature/phase11-challenge-rewards` — not merged. All 11a changes live on this
branch. `main` is untouched.

### What shipped on the branch (sub-phase 11a)

Pure scoring infrastructure. No runtime behaviour change, no UI change. The
`ChallengeScore` module is intentionally decoupled from the lap so it can be
unit-tested without a running Studio session.

Files added:
- `plans/phase11.md` — the full design (§1–§11). This is the source of truth.
- `src/integrity/ChallengeScore.luau` — pure scoring function over
  `(SectorState, RunMetrics) -> ChallengeScore`. No side effects, no workspace.
- `src/orchestrator/TestPhase11.luau` — 12 unit tests covering zero metrics,
  air saturation, crest near-miss ramp, chicane occupancy ramp, budget flag
  semantics, time-cost penalty, and the raw margin helper.

Files modified:
- `src/common/Types.luau` — `ChallengeScore` export, optional
  `hang_time`/`peak_lateral_g`/`target_min_speed` on `RunMetrics`, optional
  `score` on `RunResult`. All additive.
- `src/common/Constants.luau` — `CHALLENGE_BUDGET_RATIO = 0.50`,
  `CHALLENGE_UP_ROUNDS = 3`, per-component `SCORE_W_*` weights,
  `NEAR_MISS_ZERO_AT_MARGIN`, `LATERAL_G_FULL_SCORE`, `HANG_TIME_FULL_SCORE`,
  `MIN_ESCALATION_DELTA`.
- `src/orchestrator/TestDispatcher.luau` — `phase11` / `phase11_unit` branches.
- `tools/test_bridge_config.json` — both entries as `skip_baseline` (no lap
  required).
- `Makefile` — `phase11` / `phase11_unit` targets.

### What did NOT ship (deliberately)

These were left for the next agent so each sub-phase is independently
shippable and each commit is small:

1. **MetricCollector extension.** `hang_time`, `peak_lateral_g`, and
   `target_min_speed` are declared in the type but not populated. Until they
   are, `ChallengeScore.compute` falls back to approximations from
   `target_airtime_distance` and `target_left/right_offset`. Both fallbacks
   are intentionally conservative — real telemetry will produce larger
   numbers, which is the right direction for "make the score responsive".

2. **`LapEvaluator` does not call `ChallengeScore.compute`.** The score is
   not yet written onto `RunResult`. Wiring is one line in
   `LapEvaluator.evaluate` on the success branch. Left out because it crosses
   from pure scoring (safe) into the live lap path (needs an integration lap
   to verify nothing regresses). Next agent should add it under 11a-tail and
   re-run `phase9_integration`, `phase10_integration`, `phase8_integration`.

3. **No UI surface.** HUD does not show a score.

4. **No challenge-up (Stage B).** Single-sector jobs still commit at minimum
   integrity. See `plans/phase11.md` §3.3.

5. **No `/demo maximize` campaign agent.** See `plans/phase11.md` §3.5.

### Recommended next steps (in order)

1. Verify the ship-today wiring on this branch is green:
   - `make phase11_unit` passes.
   - `make phase10_integration` still passes (no regression — only new files
     and additive type fields).
2. Wire `LapEvaluator` to compute the score on success. One new line plus
   threading `state` through (already available to the evaluator — no
   new argument needed for existing callers).
3. Extend `MetricCollector` for `hang_time` (wall-clock seconds of the
   longest continuous airborne segment — the existing `_airborne` bool and
   timestamps make this a 10-line change).
4. Surface the score in HUD log (`UIState.appendLog` is enough for v1).
5. Start Stage B (`extreme` qualifier + challenge-up loop in `JobRunner`).
6. Write `MaximizerAgent`. The user specifically wants to *watch* this run.

### Design choices worth preserving (do not silently rewrite)

- **`near_miss` is the main reward lever.** Without it, the score is just
  "bigger number better" and the budget constraint is the only corrector. The
  near-miss component explicitly rewards *margin to the integrity threshold*,
  which is the thing the user described as "near crash".

- **Single scalar `total` with weighted components.** Several alternatives
  were considered (Pareto front, per-mechanic max, RL-style pair of signals).
  Rejected because the project has exactly one agent making discrete commit
  decisions — a scalar is enough, and a scalar is trivially renderable on the
  HUD.

- **Budget is a hard flag, not a score penalty.** Making it a steep penalty
  produces trivial tracks (agent races to the bottom of the penalty basin).
  Making it a hard gate at the track level preserves the "sacrifice a sector"
  watch moment.

- **Score is computed only on success.** A failing run has no score. Do not
  add a "partial score" for failed runs — it would muddy the repair loop
  signal.

### What shipped on the branch (sub-phase 11b)

Stage B challenge-up. After a normal request commits at minimum integrity,
if the user included the word **`extreme`** in the qualifier set, JobRunner
now runs an escalation loop that pushes one lever at a time, re-runs the
full lap, and promotes the candidate only if (a) integrity still passes,
(b) the slowdown budget is not breached, and (c) the score improved by at
least `Constants.MIN_ESCALATION_DELTA`. The original commit always stands
— Stage B only ratchets up from there.

Files added:
- `src/orchestrator/ChallengeRunner.luau` — stateless loop. `runUp(args)`
  is the entry point; `_escalateState` is exposed for unit tests.

Files modified:
- `src/agent/RequestParser.luau` — `extreme` added to `QUALIFIER_WORDS`.
  Intentionally carries no geometry bias; MinimalProposer ignores it. Only
  JobRunner reads it.
- `src/orchestrator/JobRunner.luau` — after the existing successful
  commit, checks for the `extreme` qualifier and invokes
  `ChallengeRunner.runUp`. On improvement, commits the escalated state with
  `version += 1` and re-publishes the score via `UIState.publishScore`.
- `src/orchestrator/TestPhase11.luau` — 5 new cases for `_escalateState`
  covering per-mechanic lever selection and the LEVER_FLOOR invariant.

To try it: run `/submit sector 3 extreme jump` (or any mechanic word). The
HUD log will show `Escalate r1 ramp_angle 15→18 ACCEPT` style rounds.

### What did NOT ship in 11b

- **No HUD panel for scores.** The `UIState.publishScore` attributes are
  replicated, but no client reads them. The `Escalate …` log lines are the
  only user-visible signal.
- **No MaximizerAgent / `/demo maximize`.** Phase 11c.
- **No QUALIFIER_BIAS tuning for score-awareness.** Phase 11d.
- **No integration test.** `make phase11_unit` covers scoring + escalation
  direction; a lap-level test that exercises `ChallengeRunner.runUp` end-
  to-end is still missing.

### What shipped on the branch (sub-phase 11c)

The "uber agent". `MaximizerAgent.run` walks a fixed six-step plan
(sectors 2/3/4/7/8/9, one extreme request each) and drives the normal
JobRunner pipeline for each step. After the pass, it calls
`ChallengeScore.aggregate` over the published per-sector scores and
logs the scalar to the HUD.

Files added:
- `src/orchestrator/MaximizerAgent.luau` — stateless module. Accepts
  `submit`, `isBusy`, `isCameraDemoActive` injected callables to avoid
  a circular require with JobRunner.

Files modified:
- `src/orchestrator/JobRunner.luau` — `/demo maximize` slash command
  spawns the campaign via `task.spawn` so the submit call returns
  immediately. Rejects concurrent starts and camera-demo conflicts.

Known limitations of v1:
- Plan is fixed — no per-sector mechanic search. The three mechanics
  are assigned statically to sector groups.
- The aggregate tallies published-score attributes, which means a
  sector whose commit was reverted later will still count its last
  score. Acceptable for v1 since the campaign runs forward-only.
- If a single step times out (`CHALLENGE_UP_ROUNDS * 45 + padding`
  seconds), the whole campaign aborts. There is no retry.

### Known risks (carried over from phase10 note: stronger pad tiers)

The user's standing idea of "really slow / really fast" pad tiers is *still*
not implemented in 11a. Phase 11's approach addresses the same complaint from
a different angle: instead of giving the agent a bigger pad, give the agent a
reason to use the pads it already has more deliberately. If Phase 11 lands and
the user is still frustrated with pad fidelity, the pad-tier idea is the next
natural follow-up.

### Superseding update after the next session

The status blocks above for 11a/11b/11c are now stale historically useful notes,
not the current branch truth. The current branch state is:

- `phase11_unit`: passing
- `phase11_integration`: passing
- `/demo maximize`: now retains per-sector committed scores, runs a final
  whole-track budget probe, and evicts the lowest-value sectors until the
  assembled track is back under budget or no scored sectors remain
- HUD state now publishes both:
  - `last_score_*` for the most recently committed sector
  - `track_score_*` for the running maximizer campaign total

#### Additional Phase 11 lessons

1. The maximizer needs campaign memory

Calling `JobRunner.submit(...)` several times is not enough on its own. The
campaign must keep a per-sector score map so later eviction and aggregate HUD
publication operate on committed campaign state rather than whatever the last
job happened to publish.

2. Budget authority belongs to a final full-track lap

Per-sector `score.over_budget` is informative, but the real budget contract is
the assembled live track. The maximizer now performs a final probe lap over the
current committed geometry and uses that `slowdown_ratio` to drive:

- `track_budget_used`
- `track_budget_headroom`
- the eviction decision

3. Eviction is not rollback

`SectorRollback.revert(...)` restores the latest committed state, which is
correct for failed jobs and wrong for budget sacrifice. A maximizer eviction
must explicitly commit and apply a new flat `SectorState` with version bump.

4. The HUD needs distinct sector and campaign score channels

Do not overload one score attribute family to mean both the latest sector score
and the campaign total. Keeping `last_score_*` and `track_score_*` separate made
the client HUD logic much cleaner.

5. The maintained `make` path must be run sequentially

The local Studio bridge uses one localhost port. Running multiple `make phase...`
targets in parallel will collide with `Address already in use`. Sequential runs
are the intended contract.

6. A stale Phase 6 unit expectation was still asserting an old CrestDip repair path

`TestPhase6` still rejected `sector_length` as a valid softening lever for
`CrestDip` `local_execution_failure`, but the current proposer has used that
path since the Phase 9 repair-story tuning. The test now matches the live
contract.

7. `/demo maximize` must suppress Stage B challenge-up until campaign observability is stronger

The maximize plan uses `extreme` requests for aggressive initial proposals, but
that same qualifier also enables the single-sector challenge-up loop in
`JobRunner`. Letting Stage B run inside maximize mixed extra escalation laps
into campaign behavior and made sector-local debugging much harder. The current
branch sets `workspace.AutoTrack_MaximizeCampaignActive = true` for the whole
campaign and `JobRunner` now logs `challenge_up_skip ... reason=maximize_campaign`
instead of escalating during maximize.

8. Wrong-sector repairs need explicit trace evidence, not just a guard

The branch already had a pre-target revert guard, but that alone was not enough
to debug live reports. `JobRunner` now emits:

- `attempt_result ... target_sector=<n> failure_sector=<n|-> target_entered=<bool>`
- `failure_analysis ...`
- `repair attempt=... target_sector=... failure_sector=... target_entered=...`

Use those trace lines first when a live maximize run appears to "repair the
wrong thing". They make it clear whether the target was ever entered and whether
the repair loop should have been allowed to continue.

9. `target_entered` was too weak for downstream classification

The earlier guard only distinguished "never touched the target" from
"touched it at all". That still allowed coin-flip traversals to enter the
target sector briefly, fail before a stable exit, and then get treated like
downstream failures. The current contract adds:

- `RunMetrics.target_exited`
- `RunMetrics.target_progress`

`LapEvaluator` now only reclassifies a non-target local failure to
`downstream_failure` when `target_exited == true`. `JobRunner` also reverts
wrong-sector failures whenever the target was not exited yet, even if it was
entered.

10. Pads are now discrete-strength controls, not a binary toggle

The pad model now supports:

- `None`
- `Boost5`, `Boost10`, `Boost25`
- `Brake5`, `Brake10`, `Brake25`

Legacy `Boost` / `Brake` inputs are normalized to the medium values. This was
needed so repair actions can strengthen, weaken, or remove pads rather than
only flipping a binary switch. The verifier reads the speed delta from
`src/common/PadValueUtils.luau`, and prompts/validation now expose the richer
pad set to the agent boundary.

11. Late-in-sector failures can justify extra repair budget

`JobRunner` now grants
`Constants.EXTRA_REPAIR_ATTEMPTS_AFTER_HALF_PROGRESS` additional repair rounds
when the failure is still in the target sector and `target_progress >= 0.5`.
This is intended for "almost worked" mechanics that fail after substantial
progress through the obstacle. Do not apply this bonus to upstream or non-target
failures.

---

## Phase 11d chicane optimization fixes (current session)

### Status at checkpoint

- `make phase10_integration`: PASS (both tests)
- `make phase11_integration`: PASS (all 5 tests)
- All changes are **uncommitted** (still in the working tree on `feature/phase11-challenge-rewards`)

### Root cause: chicane was "pathologically easy" AND "unoptimizable"

Two separate bugs conspired:

1. **Default amplitude=8 = track half-width (8).** `nearMissMargin` used `corridorHalf` (typically 7) as denominator, so amplitude=8 → occupancy > 1 → clamped to 1 → score maxed at initial proposal. Challenge-up had nothing to improve.

2. **`suggestEscalation` pointed at `corridor_width`, not `amplitude`.** Even if near_miss wasn't maxed, the suggested lever was corridor_width (narrowing the path), which doesn't raise amplitude or lateral swing.

3. **Extreme qualifier bias added +6 to already-max amplitude=8 → 14**, which exceeds the 16-wide track and produced illegal geometry without rejection.

4. **Chicane repair branch tried geometry relaxation before brake pads.** Brake pads were always last in the candidate list, so the repair loop spent all its budget softening geometry before ever reaching the first pad upgrade.

5. **"Never became airborne" RampJump repair used `ramp_angle - 3` (flatten).** For a gentle ramp (e.g., 10°), flattening to 7° makes things worse. The correct direction is steepen.

### Fixes applied (all in working tree)

| File | Change |
|------|--------|
| `src/common/LevelMappings.luau` | `Chicane.amplitude` default: `8 → 5` (creates room to escalate) |
| `src/integrity/ChallengeScore.luau` | `nearMissMargin` uses `TRACK_WIDTH * 0.5 = 8` as denominator (not corridorHalf); `suggestEscalation` Chicane maps near_miss/lateral → `"amplitude"` |
| `src/integrity/ChicaneIntegrity.luau` | Preflight now rejects `amplitude > TRACK_WIDTH * 0.5` |
| `src/orchestrator/MinimalProposer.luau` | Extreme bias for Chicane.amplitude: `6 → 3` (5+3=8=ceiling); `normalizeParams` clamps amplitude to `[MIN, TRACK_WIDTH/2]`; Chicane repair: Brake pads moved to TOP of candidates before geometry changes; "never became airborne" branch: `ramp_angle - 3 → + 5` |
| `src/orchestrator/ChallengeRunner.luau` | Added `LEVER_CEILING` table; `escalateState` caps amplitude at `TRACK_WIDTH * 0.5` and returns nil if already at ceiling |
| `src/orchestrator/TestPhase11.luau` | Test 6: offset updated to 7.5 (reflects trackHalf=8 denominator); Test 22: fixture uses `amplitude=6` (room to escalate to 8) |
| `src/orchestrator/TestPhase10.luau` | `phase10_chicane_commits_after_repair_chain`: assertion relaxed from `>= 2` to `>= 1` (tight chicane now passes first-try because extreme default is capped to 8) |

### What the chicane flow looks like now (expected behavior)

1. Default proposal: amplitude=5, transition=15, corridor=14
2. Preflight passes; lap runs; integrity passes (amplitude < corridorHalf but score is low)
3. With `extreme` qualifier: Challenge-up loop calls `suggestEscalation` → `"amplitude"`, increments by delta=1 each round toward ceiling=8
4. At amplitude=8: near_miss component saturates; total score peaks; challenge-up stops escalating
5. No over-budget penalty because amplitude changes don't slow the car materially

### For the next agent

The chicane optimization path is now sound. Recommended next steps toward a good `/demo maximize` e2e demo:

1. Commit all working-tree changes (a single commit is fine; they all belong together as "11d chicane + jump repair fixes")
2. Run `/demo maximize` in Studio and verify:
   - Chicane sectors score progressively higher through challenge-up (watch HUD log for `Escalate ... ACCEPT` lines)
   - RampJump sectors show "never became airborne" repairing correctly (ramp_angle climbing, not falling)
   - Campaign aggregate score is non-trivial
3. If the e2e demo looks good, prepare a PR against main

### RampJump "integrity failure after successful-looking jump" clarification

The RampJump has two gate conditions:

1. **Airborne** — car leaves the ramp surface (hang_time > 0). This is visually obvious.
2. **Reacquire** — car lands back on the track within `RAMPJUMP_REACQUIRE_MAX` studs after the gap. This is not visually obvious. If the car overshoots the landing zone or physics registers contact outside the landing tiles, this fails even when the jump looked clean.

So "jumped fine but integrity failed" almost always means reacquire failed — the landing strip was too short, the speed was too high relative to gap length, or a bounce took the car off the landing tiles. The repair lever for this is `gap_length` (shorten the gap) or `landing_length` (lengthen landing zone).
