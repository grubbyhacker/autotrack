# Phase 1 — Chunked Implementation Tasks

Feed each chunk to Sonnet one at a time. Each chunk is self-contained (1-2 files).

## Constant/Type discrepancies to fix

- STRAIGHT_LENGTH: change 60 to 120
- TRACK_WIDTH: change 20 to 16
- Keep existing SectorDescriptor type name (already in scaffold)

---

## Chunk 1: Constants + Types

Files: src/common/Constants.luau, src/common/Types.luau

In Constants.luau:
- Change STRAIGHT_LENGTH from 60 to 120
- Change TRACK_WIDTH from 20 to 16
- Add: BASELINE_SPEED = 40
- Add: PAD_BOOST_FORCE = 6000
- Add: PAD_BRAKE_FORCE = -4000
- Add: CAR_WIDTH = 4, CAR_HEIGHT = 2, CAR_LENGTH = 8
- Add: WAYPOINT_LOOKAHEAD = 1

In Types.luau, add these type aliases (leave everything else as-is):
- SectorKind = "Straight" | "Corner"
- SectorMeta = { id: number, kind: SectorKind, entry: CFrame, exit: CFrame, partGroup: Folder? }

---

## Chunk 2: TrackGenerator topology math

File: src/track/TrackGenerator.luau

Implement generate(rows, cols) returning {SectorDescriptor}. Pure CFrame math, no Part creation.

2x5 grid = 10 sectors clockwise. Corners at 1, 5, 6, 10. Straights at 2, 3, 4, 7, 8, 9.

Layout must read as a clean rectangle made of 10 sectors that mate edge-to-edge.
Corner sectors may be compact square turn plates.
Straight sectors may be longer rectangles in the direction of travel than the corner sectors.

Path: the lap order remains clockwise 1,2,3,4,5,6,7,8,9,10, with the top row running left-to-right and the bottom row running right-to-left in physical placement.

Each straight segment uses STRAIGHT_LENGTH (120 studs) as its travel length. Each corner is a compact 90-degree turn sector based on CORNER_RADIUS (20 studs) and TRACK_WIDTH.

Entry CFrame faces travel direction (LookVector = travel direction). Exit CFrame = next sector's entry.

Also implement canonicalStart() returning the CFrame before sector 1.

---

## Chunk 3: TrackGenerator Part spawning

File: src/track/TrackGenerator.luau

Add function buildParts(sectors: {SectorDescriptor}) that creates physical Parts in Workspace:
- Create a Folder named "Track" in Workspace
- For each sector, create an Anchored Part
- Straights: use longer rectangular Parts aligned with travel direction
- Corners: use square bounding boxes for the turn sectors
- Color corners BrickColor "Medium stone grey", straights "Dark stone grey"
- Set Material to SmoothPlastic on all parts
- Parent each Part to the Track folder

---

## Chunk 4: SectorRegistry init

File: src/track/SectorRegistry.luau

Implement init(straightCount) to populate _committed with flat baseline SectorState for each editable straight (sector IDs for straights are: 2,3,4,7,8,9 in 2x5 grid). Each starts with no mechanic (leave mechanic field nil or use a sentinel), pads = {ingress="None", egress="None"}, version = 0.

Add getStraights() that returns all committed states as an array.
Add get(id) as alias for getCommitted(id).

---

## Chunk 5: JobLock

File: src/orchestrator/JobLock.luau (NEW FILE)

Simple mutex module:

```lua
local JobLock = {}
local _held = false

function JobLock.tryAcquire(): boolean
    if _held then return false end
    _held = true
    return true
end

function JobLock.release()
    _held = false
end

function JobLock.isHeld(): boolean
    return _held
end

return JobLock
```

---

## Chunk 6: VerifierCar + VerifierController

Files: src/verifier/VerifierCar.luau, src/verifier/VerifierController.luau

Replace the existing VerifierCar scaffold entirely. Phase 1 version spawns a Part directly (no MCP Model):
- spawn(startCFrame: CFrame): BasePart — creates a 4x2x8 Part with Anchored=false, CanCollide=true, CustomPhysicalProperties(density=1, friction=0.5, elasticity=0). Parent to Workspace.
- reset(startCFrame: CFrame) — sets CFrame, zeros AssemblyLinearVelocity and AssemblyAngularVelocity
- destroy() — Destroy() the part, nil out reference
- getPart(): BasePart — returns the part reference

Replace the existing VerifierController scaffold entirely. Phase 1 version is a simple waypoint follower (not the Phase 3 semi-rail):
- runLap(car: BasePart, waypoints: {CFrame}): Types.RunResult
- Create a LinearVelocity constraint (ForceLimitMode=Magnitude, MaxForce=10000, VelocityConstraintMode=Vector, RelativeTo=World) attached to car
- Create an AlignOrientation constraint (MaxTorque=100000, Responsiveness=20) attached to car
- Each Heartbeat frame: compute direction to current waypoint, set LinearVelocity to direction * CAR_TARGET_SPEED, set AlignOrientation CFrame to face waypoint
- Advance to next waypoint when car is within 10 studs of current target
- Lap complete when car passes all waypoints
- Failure if car is more than TRACK_WIDTH studs laterally from the line between consecutive waypoints
- Timeout after LAP_TIMEOUT seconds = system_failure
- Clean up constraints, return RunResult with success, lap_time, and zeroed/placeholder metrics
- Use task.wait() style yielding (connect to Heartbeat, yield with a BindableEvent or coroutine)

---

## Chunk 7: Main boot script

File: src/orchestrator/Main.server.luau (NEW FILE — .server.luau makes Rojo treat it as a Script)

Require paths (relative to ServerScriptService.AutoTrackCore.Orchestrator):
- TrackGenerator: script.Parent.Parent.Track.TrackGenerator
- SectorRegistry: script.Parent.Parent.Track.SectorRegistry
- VerifierCar: script.Parent.Parent.Verifier.VerifierCar
- VerifierController: script.Parent.Parent.Verifier.VerifierController
- JobLock: script.Parent.JobLock
- Constants: game.ReplicatedStorage.AutoTrackCommon.Constants

Boot sequence:
1. print("[AutoTrack] Booting Phase 1...")
2. local sectors = TrackGenerator.generate()
3. TrackGenerator.buildParts(sectors)
4. SectorRegistry.init(6) -- 6 editable straights in 2x5
5. local startCF = TrackGenerator.canonicalStart()
6. local car = VerifierCar.spawn(startCF)
7. Extract waypoints from sectors
   The waypoint path must follow the full rectangle and must not cut diagonally across corners
8. assert(JobLock.tryAcquire(), "JobLock busy")
9. local result = VerifierController.runLap(car, waypoints)
10. JobLock.release()
11. if result.success then print("[AutoTrack] Baseline lap complete: " .. result.metrics.lap_time .. "s")
12. else print("[AutoTrack] Baseline lap FAILED: " .. tostring(result.failure))
13. Store result.metrics.lap_time in a local variable
