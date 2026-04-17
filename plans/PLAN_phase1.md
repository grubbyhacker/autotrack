# Phase 1 Plan — Static Skeleton + Baseline Lap

## Context

AutoTrack's Phase 1 goal (PRD §17.1) is to produce a flat rectangular track visible in Studio, with all sectors registered and numbered, a global job lock, and a basic verifier car that can complete a baseline lap end-to-end. This proves the physical scaffold before any mechanic builders, semi-rail tuning, or LLM integration are touched.

Deliverable: **flat baseline lap succeeds end to end** (visible in Studio output/console).

---

## What this phase does NOT include

- Sector applier / rollback (Phase 2)
- Semi-rail controller (Phase 3 replaces the crude Phase 1 car)
- Any mechanic builder (Phase 4)
- LLM adapter (Phase 7)
- UI (Phase 8)

---

## Physical constants (all confirmed)

| Constant | Value | Notes |
|---|---|---|
| `ROWS` | 2 | default grid |
| `COLS` | 5 | default grid |
| `STRAIGHT_LENGTH` | 120 studs | per sector |
| `TRACK_WIDTH` | 16 studs | corridor |
| `TRACK_THICKNESS` | 2 studs | part height |
| `CORNER_RADIUS` | 20 studs | inner radius of turn |
| `WORLD_ORIGIN` | CFrame(0, 0, 0) | track starts here |
| `CAR_SIZE` | 4×2×8 studs | W×H×L |
| `CAR_TARGET_SPEED` | 40 studs/s | initial baseline |
| `WAYPOINT_LOOKAHEAD` | 1 | car steers to next waypoint |

Track topology for 2×5: **10 total sectors** (`rows × cols = 2 × 5 = 10`), numbered 1–10 clockwise from the canonical start. 4 fixed corner sectors (one at each literal corner of the rectangle) + 6 editable straight sectors (3 top + 3 bottom).

Straight sectors do **not** need to be the same footprint as corner sectors. Phase 1 should use:
- corner sectors as compact square turn plates
- straight sectors as longer rectangular plates in the direction of travel
- all sectors mated edge-to-edge with no gaps or overlaps, so the overall track still reads as one clean rectangle

---

## Files to create / fill in

### `src/common/Types.luau`
Define all normative schema types as Luau type aliases:
- `Request`, `SectorState`, `AgentAction`, `RunResult`, `FailurePacket`, `CIJob`
- `PadValue = "None" | "Boost" | "Brake"`
- `MechanicType = "RampJump" | "Chicane" | "CrestDip"`
- `SectorKind = "Straight" | "Corner"`
- `SectorMeta` — registry entry: `{ id, kind, entry: CFrame, exit: CFrame, partGroup: Folder }`

### `src/common/Constants.luau`
All physical constants listed in the table above, plus:
- `MAX_REPAIR_ATTEMPTS = 5`
- `PAD_BOOST_FORCE = 6000` (studs/s² impulse — tunable)
- `PAD_BRAKE_FORCE = -4000`
- `BASELINE_SPEED = 40`

### `src/track/TrackGenerator.luau`
Module that builds the physical track in `Workspace` and returns a list of `SectorMeta`:
- Generates an explicit 2×5 rectangular sector layout with clockwise ordering
- Computes entry/exit CFrames for each sector from sector-to-sector adjacency
- Spawns a `Part` (road surface) per sector, parented to a `Workspace.Track` folder
- Corner parts are simple filled squares; straight parts are longer rectangles in the direction of travel
- Returns ordered `SectorMeta[]` for registry consumption
- No mechanic geometry yet — all sectors are flat road

Key function: `TrackGenerator.generate(rows, cols): SectorMeta[]`

### `src/track/SectorRegistry.luau`
Singleton module that wraps the `SectorMeta[]` array:
- `SectorRegistry.init(sectors: SectorMeta[])` — called once at boot
- `SectorRegistry.get(id: int): SectorMeta`
- `SectorRegistry.getStraights(): SectorMeta[]`
- `SectorRegistry.count(): int`
- Stores the current `committedState: {[int]: SectorState}` table (starts as all-flat / no mechanic)

### `src/orchestrator/JobLock.luau` *(new file, not in original stub list)*
Simple mutex:
- `JobLock.tryAcquire(): bool` — returns false if busy
- `JobLock.release()`
- `JobLock.isHeld(): bool`

### `src/verifier/VerifierCar.luau`
Spawns the single canonical car `Part` into `Workspace`:
- Fixed size, physics profile (`Density`, `Friction`, `Elasticity`, etc.)
- `VerifierCar.spawn(startCFrame: CFrame): Part`
- `VerifierCar.reset(startCFrame: CFrame)` — moves car back to canonical start, zeroes velocity
- `VerifierCar.destroy()`

### `src/verifier/VerifierController.luau`
Phase 1 version: **simplified waypoint follower** (not semi-rail yet; Phase 3 replaces this):
- Receives ordered waypoints (sector entry CFrames)
- Uses `LinearVelocityConstraint` + `AlignOrientation` to drive car toward next waypoint
- Detects lap completion when car passes final waypoint
- Detects failure if car goes off-track (exceeds lateral threshold from current waypoint path)
- `VerifierController.runLap(car: Part, waypoints: CFrame[]): RunResult`
- Returns a minimal `RunResult` with `success`, `lap_time`, and placeholder metric fields

### `src/orchestrator/Main.server.luau` *(new file — boot Script)*
The only auto-running Script in Phase 1:
```
1. Build track via TrackGenerator
2. Init SectorRegistry
3. Spawn verifier car at canonical start
4. Acquire job lock
5. Run baseline lap via VerifierController
6. Release job lock
7. Print result to console
8. Store baseline lap time in a module-level variable
```

---

## Canonical sector numbering (2×5)

```
→ C(1) → S(2) → S(3) → S(4) → C(5) →
↑                                    ↓
← C(10) ← S(9) ← S(8) ← S(7) ← C(6) ←

2 rows × 5 cols = 10 tiles total
4 corner tiles: 1, 5, 6, 10
6 straight tiles: 2, 3, 4 (top); 7, 8, 9 (bottom, traversed right→left)
```

---

## Entry/Exit CFrame convention

- Each sector's `entry` CFrame = leading edge center (facing the direction of travel)
- Each sector's `exit` CFrame = trailing edge center = next sector's `entry`
- Y-axis = up, LookVector = travel direction
- Generated purely from the grid math; never mutated after generation

---

## Verification step (how to confirm Phase 1 is working)

1. Open Studio with Rojo sync running
2. Play the experience
3. Observe: track appears in Workspace as a clear 10-sector rectangle
4. Observe: four corner sectors and six straight sectors are visibly distinct and mate perfectly
5. Observe: verifier car spawns and drives a full lap around that rectangle
6. Console prints: `[AutoTrack] Baseline lap complete: <time>s` OR failure reason
7. No errors in output log

---

## Confirmed decisions

- Studio is open, Rojo is syncing, blank/baseplate place is loaded — ready to test
- Constraint API: **new API** (`LinearVelocityConstraint` + `AlignOrientation`)
- Physical constants: all defaults confirmed
