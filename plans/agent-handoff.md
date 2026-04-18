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
