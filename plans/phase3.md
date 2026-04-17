# Phase 3 — Semi-Rail Verifier with Real Metrics

## Deliverable

Replace placeholder `RunMetrics` (all zeros) with real metric collection. Add semi-rail guidance (strong forward, weak lateral). Add airborne detection via downward raycast and reacquisition tracking.

Test: verifier reliably completes flat lap; off-track scenarios fail correctly; metrics are populated.

---

## Files to create/modify

| File | Action |
|------|--------|
| `src/verifier/ReacquireDetector.luau` | Implement stub |
| `src/verifier/MetricCollector.luau` | Implement stub |
| `src/verifier/FailureDetector.luau` | Extend stub |
| `src/verifier/VerifierController.luau` | Rewrite main loop |
| `src/orchestrator/TestPhase3.luau` | New test suite |
| `src/orchestrator/TestRunner.server.luau` | Add `phase3` dispatch branch |

---

## Implementation

### ReacquireDetector.luau

```lua
local GROUNDED_THRESHOLD = Constants.CAR_HEIGHT * 0.5 + Constants.TRACK_THICKNESS + 1.5  -- ≈ 4.5 studs

function ReacquireDetector.isGrounded(position: Vector3, raycastParams: RaycastParams): boolean
    local result = workspace:Raycast(position, Vector3.new(0, -GROUNDED_THRESHOLD, 0), raycastParams)
    return result ~= nil
end
```

The caller (VerifierController) creates `RaycastParams` once before the loop:

```lua
local rayParams = RaycastParams.new()
rayParams.FilterDescendantsInstances = {car}
rayParams.FilterType = Enum.RaycastFilterType.Exclude
```

### MetricCollector.luau

Module-level state (all reset per run):

```lua
local _maxLateralError = 0
local _maxVerticalDisplacement = 0
local _baselineY = 0
local _airborne = false
local _everAirborne = false
local _liftoffPosition = Vector3.zero
local _airDistance = 0
local _everReacquired = false
local _lastPosition = Vector3.zero
local _sectorEntrySpeed: {[number]: number} = {}
local _sectorExitSpeed:  {[number]: number} = {}
```

`reset(baselineY: number)` — clear all state, store `_baselineY`.

`record(speed, position, isAirborne, lateralError)` — per-frame:
- `_maxLateralError = max(_maxLateralError, abs(lateralError))`
- `_maxVerticalDisplacement = max(_maxVerticalDisplacement, abs(position.Y - _baselineY))`
- Airborne state machine:
  - `isAirborne and not _airborne` → set `_airborne = true`, `_everAirborne = true`, `_liftoffPosition = position`
  - `not isAirborne and _airborne` → set `_airborne = false`, `_everReacquired = true`, accumulate last segment
  - While airborne: `_airDistance += (position - _lastPosition).Magnitude` each frame
- Update `_lastPosition = position`

`onSectorEntry(sector_id, speed)` → `_sectorEntrySpeed[sector_id] = speed`
`onSectorExit(sector_id, speed)` → `_sectorExitSpeed[sector_id] = speed`

`finalise(targetSector: number, lapTime: number, baselineLapTime: number): RunMetrics`:
- `reacquired = if _everAirborne then _everReacquired else true`
- `slowdown_ratio = lapTime / math.max(baselineLapTime, 0.001)`
- Look up entry/exit speeds for `targetSector` from maps (default 0)
- Return full `RunMetrics` table

### FailureDetector.luau

Extend `check` signature:

```lua
function FailureDetector.check(
    elapsed: number,
    currentSector: number,
    carPosition: Vector3,
    trackCenterlinePoint: Vector3,
    isAirborne: boolean
): FailureInfo?
```

Checks (in order):
1. `elapsed >= LAP_TIMEOUT` → `{ type = "system_failure", sector_id = currentSector }`
2. `carPosition.Y < -50` → `{ type = "local_execution_failure", sector_id = currentSector }`
3. `not isAirborne and (carPosition - trackCenterlinePoint).Magnitude > TRACK_WIDTH * 1.5` → `local_execution_failure`

### VerifierController.luau (rewrite)

Signature unchanged: `runLap(car, waypoints, sectors?, onSectorChange?) → RunResult`

**Setup before loop:**

```lua
local rayParams = RaycastParams.new()
rayParams.FilterDescendantsInstances = {car}
rayParams.FilterType = Enum.RaycastFilterType.Exclude

MetricCollector.reset(car.Position.Y)
local baselineLapTime = workspace:GetAttribute("AutoTrack_BaselineLapTime") or 30
```

Reduce orientation responsiveness: `alignOrientation.Responsiveness = 5` (was 20).

**Per-frame:**

```lua
local isAirborne = not ReacquireDetector.isGrounded(carPosition, rayParams)
local speed = car.AssemblyLinearVelocity.Magnitude
local projectedPoint, _ = projectPointToSegment(carPosition, segStart, segEnd)
local lateralError = (carPosition - projectedPoint).Magnitude

MetricCollector.record(speed, carPosition, isAirborne, lateralError)

-- Forward: always apply target speed toward waypoint
linearVelocity.VectorVelocity = moveDirection * Constants.CAR_TARGET_SPEED

-- Lateral correction: grounded only
if isAirborne then
    alignOrientation.MaxTorque = 0      -- let physics orient freely
else
    alignOrientation.MaxTorque = 10000
    alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, lookDirection)
    -- optional weak lateral nudge if lateralError > 1 stud
end

-- Failure check
local failure = FailureDetector.check(elapsed, currentSectorId or 1,
    carPosition, projectedPoint, isAirborne)
if failure then
    -- cleanup constraints
    local metrics = MetricCollector.finalise(currentSectorId or 1, elapsed, baselineLapTime)
    return { success = false, failure = failure, metrics = metrics }
end
```

**Wrap `onSectorChange` to capture speeds:**

```lua
local function handleSectorChange(id, entering)
    local spd = car.AssemblyLinearVelocity.Magnitude
    if entering then
        MetricCollector.onSectorEntry(id, spd)
    else
        MetricCollector.onSectorExit(id, spd)
    end
    if onSectorChange then onSectorChange(id, entering) end
end
```

Pass `handleSectorChange` instead of `onSectorChange` to the sector-tracking loop.

**On completion:**

```lua
local lapTime = os.clock() - startTime
-- cleanup constraints
local metrics = MetricCollector.finalise(currentSectorId or 1, lapTime, baselineLapTime)
return { success = true, failure = nil, metrics = metrics }
```

Remove `buildPlaceholderMetrics` and `buildFailure` — replaced by MetricCollector.

### TestPhase3.luau

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local ReacquireDetector = require(script.Parent.Parent.Verifier.ReacquireDetector)
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
```

Six tests:

**1. `semirail_flat_lap_completes`**
```lua
-- regenerate + run a fresh lap
local sectors = TrackGenerator.generate()
local waypoints = TrackGenerator.getLapWaypoints(sectors)
VerifierCar.reset(TrackGenerator.canonicalStart())
local car = VerifierCar.getPart()
local result = VerifierController.runLap(car, waypoints, sectors, nil)
T.expect("semirail_flat_lap_completes", result.success == true,
    "lap failed: " .. tostring(result.failure and result.failure.type))
```

**2. `metrics_lap_time_positive`** — reuse `result` above:
```lua
T.expect("metrics_lap_time_positive", result.metrics.lap_time > 0,
    "lap_time=" .. tostring(result.metrics.lap_time))
```

**3. `metrics_entry_speed_captured`**
```lua
T.expect("metrics_entry_speed_captured", result.metrics.entry_speed > 0,
    "entry_speed=" .. tostring(result.metrics.entry_speed))
```

**4. `reacquire_grounded_on_track`**
```lua
VerifierCar.reset(TrackGenerator.canonicalStart())
local car = VerifierCar.getPart()
local rp = RaycastParams.new()
rp.FilterDescendantsInstances = {car}
rp.FilterType = Enum.RaycastFilterType.Exclude
T.expect("reacquire_grounded_on_track",
    ReacquireDetector.isGrounded(car.Position, rp) == true,
    "car not grounded on flat track")
```

**5. `reacquire_airborne_above_track`**
```lua
VerifierCar.reset(TrackGenerator.canonicalStart() * CFrame.new(0, 20, 0))
local car2 = VerifierCar.getPart()
local rp2 = RaycastParams.new()
rp2.FilterDescendantsInstances = {car2}
rp2.FilterType = Enum.RaycastFilterType.Exclude
T.expect("reacquire_airborne_above_track",
    ReacquireDetector.isGrounded(car2.Position, rp2) == false,
    "car incorrectly grounded 20 studs above track")
VerifierCar.reset(TrackGenerator.canonicalStart())
```

**6. `failure_off_track_detected`**
```lua
VerifierCar.reset(CFrame.new(9999, 3, 9999))
local car3 = VerifierCar.getPart()
local sectors3 = TrackGenerator.generate()
local waypoints3 = TrackGenerator.getLapWaypoints(sectors3)
local ok, result3 = pcall(function()
    return VerifierController.runLap(car3, waypoints3, sectors3, nil)
end)
T.expect("failure_off_track_detected",
    (ok and result3.success == false) or not ok,
    "expected failure for off-track car")
VerifierCar.reset(TrackGenerator.canonicalStart())
```

### TestRunner.server.luau

Add:
```lua
elseif cmd == "phase3" then
    require(script.Parent.TestPhase3).run()
```

---

## Test pass criteria

| Test | Pass condition |
|------|---------------|
| `semirail_flat_lap_completes` | `result.success == true` |
| `metrics_lap_time_positive` | `result.metrics.lap_time > 0` |
| `metrics_entry_speed_captured` | `result.metrics.entry_speed > 0` |
| `reacquire_grounded_on_track` | `isGrounded == true` on flat track |
| `reacquire_airborne_above_track` | `isGrounded == false` 20 studs up |
| `failure_off_track_detected` | `result.success == false` from off-track start |

---

## Verification steps

1. Start Play, await `[AutoTrack] Baseline lap complete`.
2. `game.ReplicatedStorage:WaitForChild("AutoTrack_TestCmd", 5):FireServer("phase3")`.
3. Expect 6 `[TEST PASS]` lines and `[TEST] Suite done: phase3`.
4. Confirm `[TRACE] sector_enter 2 speed=XX.X` shows non-zero speed in console.
5. Regression: also run `FireServer("phase1")` and `FireServer("phase2")`.
