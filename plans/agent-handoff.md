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
| 7 | **Next** — LLM adapter (narrow boundary, swappable backend) |
| 8 | Pending |

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
