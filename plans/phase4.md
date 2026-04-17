# Phase 4 — Staged Mechanic Builders

## Summary

Phase 4 is no longer a single all-at-once mechanic drop. Build and validate it in four staged subphases:

1. `PadBuilder` + shared Phase 4 test harness
2. `RampJumpBuilder`
3. `CrestDipBuilder`
4. `ChicaneBuilder`

Keep the current startup behavior unchanged:

- boot the track
- run one flat, no-pad baseline lap
- persist `AutoTrack_BaselineLapDone` and `AutoTrack_BaselineLapTime`

That boot lap remains the control run. Phase 4 authored-content validation happens only after the baseline lap succeeds.

---

## Deliverable

By the end of Phase 4, every legal v1 mechanic sector can be rendered deterministically by `SectorApplier.apply()`. Delivery is staged so testing lessons from pads and `RampJump` are applied before `CrestDip` and `Chicane`.

Intermediate success criteria:

- Phase 4A: pads render deterministically and can be reapplied/cleared safely
- Phase 4B: `RampJump` renders correctly and survives a post-baseline second-lap validation run
- Phase 4C: `CrestDip` renders correctly and survives a post-baseline second-lap validation run
- Phase 4D: `Chicane` renders as linked slow corners in an overall S shape and preserves entry/exit alignment; stronger runtime integrity remains deferred until observability is sufficient

---

## Files to Create or Modify

| File | Action |
|------|--------|
| `src/mechanics/PadBuilder.luau` | Implement in Phase 4A |
| `src/mechanics/RampJumpBuilder.luau` | Implement in Phase 4B |
| `src/mechanics/CrestDipBuilder.luau` | Implement in Phase 4C |
| `src/mechanics/ChicaneBuilder.luau` | Implement in Phase 4D |
| `src/track/SectorApplier.luau` | Pass `sector_id` into pad application |
| `src/orchestrator/TestPhase4.luau` | New staged test suite |
| `src/orchestrator/TestRunner.server.luau` | Add `phase4` dispatch branch |

Optional persisted note:

| File | Action |
|------|--------|
| `plans/phase4-testing.md` | Detailed baseline-first and second-lap test methodology |

---

## Test Methodology

Do not fold Phase 4 authored content into the startup lap.

### Control run

`Main.server.luau` continues to:

1. generate the flat track
2. spawn/reset the verifier car
3. run one flat full-lap baseline verification
4. write baseline attributes used by later tests

This keeps boot diagnostics stable and preserves a clean slowdown baseline.

### Phase 4 authored-content tests

`TestPhase4.luau` is responsible for all Phase 4 content validation:

1. assert baseline boot lap already succeeded
2. apply authored content to one straight sector
3. inspect Workspace geometry directly
4. reset the verifier car to canonical start
5. run a second full lap when runtime validation is needed
6. assert on returned `RunResult` and on live Workspace state
7. restore the target sector to flat before the next case

Use direct module calls. Do not simulate UI input.

---

## Coordinate Convention

All builders receive `entryFrame: CFrame` and `exitFrame: CFrame` from `SectorApplier`. The entry frame is the local origin for all geometry:

- `worldCF = entryFrame * localOffset`
- local `+Z` = forward (`entryFrame.LookVector`)
- local `+Y` = up (`entryFrame.UpVector`)
- local `+X` = right (`entryFrame.RightVector`)
- `entryFrame.Position.Y` = track center Y = `TRACK_THICKNESS / 2`

All Phase 4 geometry must stay inside the targeted straight sector and must not alter neighboring sectors, corners, or track topology.

Sector completeness invariant:

- if a mechanic uses less than `STRAIGHT_LENGTH`, it must still provide a continuous drivable path to the sector boundary
- intentional gaps are allowed only when the mechanic explicitly defines the landing/rejoin surface afterward
- no builder may terminate early and leave empty space to the next corner

---

## Shared Helpers

Use the same deterministic helper pattern across builders:

```lua
local function getSectorFolder(sector_id: number): Folder
    local name = string.format("Sector_%02d", sector_id)
    local track = workspace:FindFirstChild("Track")
    local folder = track and track:FindFirstChild(name)
    assert(folder, "getSectorFolder: not found: " .. name)
    return folder :: Folder
end

local function makePart(
    name: string,
    size: Vector3,
    cf: CFrame,
    color: BrickColor,
    parent: Instance
): Part
    local p = Instance.new("Part")
    p.Name = name
    p.Size = size
    p.CFrame = cf
    p.Anchored = true
    p.CanCollide = true
    p.TopSurface = Enum.SurfaceType.Smooth
    p.BottomSurface = Enum.SurfaceType.Smooth
    p.Material = Enum.Material.SmoothPlastic
    p.BrickColor = color
    p.Parent = parent
    return p
end
```

Use matching helper functions in `TestPhase4.luau` for:

- finding sector folders and authored parts
- asserting deterministic child sets
- resetting the car and running a second lap
- restoring a sector to flat between cases

---

## SectorApplier Change

Pass `state.sector_id` to `PadBuilder.applyPads`.

```lua
-- Before:
PadBuilder.applyPads(state.pads, entryFrame, exitFrame)

-- After:
PadBuilder.applyPads(state.pads, entryFrame, exitFrame, state.sector_id)
```

---

## Phase 4A — PadBuilder

### Scope

Implement visible deterministic ingress/egress pads for straight sectors.

### Signature

`applyPads(pads: Pads, ingressFrame: CFrame, egressFrame: CFrame, sector_id: number)`

### Behavior

- destroy stale `IngressPad` / `EgressPad` parts before rebuilding
- create no pad part for `None`
- create one visible non-colliding part per non-`None` pad
- set `PadType` attribute to `Boost` or `Brake`
- keep pad placement just above the track surface
- parent pad parts into the target sector folder only

### Phase 4A tests

- `baseline_control_still_complete`
- `pads_none_creates_no_parts`
- `pads_boost_and_brake_create_expected_named_parts`
- `pads_reapply_replaces_stale_parts`
- `pads_apply_does_not_break_traversal` if a light second-lap sanity run is desired

Do not require quantitative speed-change assertions in this slice unless pad effects already exist in the runtime. The required outcome is correct rendering and non-breaking traversal.

---

## Phase 4B — RampJumpBuilder

### Why RampJump first

`RampJump` is the first full mechanic because Phase 3 already exposes the runtime signals needed to validate it:

- `metrics.airborne`
- `metrics.air_distance`
- `metrics.reacquired`
- `metrics.lap_time`

This makes it the best first end-to-end authored mechanic.

### Params

- `ramp_angle`
- `ramp_length`
- `gap_length`
- `landing_length`

### Derived values

```lua
local angleRad = math.rad(p.ramp_angle)
local rampH = p.ramp_length * math.tan(angleRad)
local rampSurfLen = p.ramp_length / math.cos(angleRad)
local totalHoriz = p.ramp_length + p.gap_length + p.landing_length

assert(
    totalHoriz <= Constants.STRAIGHT_LENGTH,
    "RampJumpBuilder: geometry exceeds STRAIGHT_LENGTH (" .. totalHoriz .. ")"
)
```

### Geometry

- one tilted `Ramp` part
- one flat `Landing` part
- empty gap between them
- no part may extend beyond the owning straight sector

### Phase 4B tests

Geometry assertions:

- `rampjump_build_creates_ramp_and_landing`
- `rampjump_gap_has_no_middle_part`
- `rampjump_ramp_tilt_is_positive`
- `rampjump_invalid_length_errors`

Runtime second-lap assertions:

1. baseline lap already complete
2. apply one legal `RampJump` state to a straight sector
3. reset car to canonical start
4. run a second full lap
5. assert:
   - `result.success == true`
   - `result.metrics.airborne == true`
   - `result.metrics.air_distance > 0`
   - `result.metrics.reacquired == true`
   - `result.metrics.lap_time > 0`

Add one negative authored case that is either rejected fast or predictably fails the run. Do not attempt to fully implement Phase 5 integrity semantics here.

---

## Phase 4C — CrestDipBuilder

### Why next

`CrestDip` can reuse the same second-lap methodology as `RampJump` and already has supporting telemetry:

- `metrics.vertical_displacement`
- `metrics.reacquired`

### Params

- `height_or_depth`
- `radius`
- `sector_length`

### Geometry

- crest: one up-ramp part and one down-ramp part
- dip: one down-ramp part and one up-ramp part
- geometry must stay inside the straight sector

### Phase 4C tests

- `crestdip_crest_builds_two_parts`
- `crestdip_dip_builds_two_parts`
- `crestdip_illegal_length_errors`
- one second-lap case asserting successful traversal and non-zero `vertical_displacement`

---

## Phase 4D — ChicaneBuilder

### Why last

`Chicane` is last because current runtime observability is weakest for its integrity model. The PRD now treats it as a compound-corner S, not a lane shift, but current `RunMetrics` still does not expose full lateral-path telemetry.

### Params

- `amplitude` = peak lateral centerline offset reached during the linked turns
- `transition_length` = longitudinal budget for each turning phase in the S
- `corridor_width` = actual rendered drivable width

### Geometry

Build deterministic compound-corner geometry that:

- enters on the original sector centerline
- traverses to one lateral side
- reverses through the opposite side
- unwinds back to the original exit line
- preserves the sector entry and exit transforms

Use multiple short authored subsegments to approximate the three turning phases. Do not model this as flat-offset corridors joined by a couple of diagonals.

### Phase 4D tests

Required now:

- `chicane_build_creates_expected_segment_set`
- `chicane_geometry_uses_both_lateral_sides`
- `chicane_entry_and_exit_centerlines_preserved`
- `chicane_illegal_total_length_errors`
- `chicane_apply_is_deterministic`
- basic second-lap traversability sanity check if the current verifier can complete it reliably

Deferred:

- stronger runtime assertions for alternating signed lateral deflections, curvature severity, and speed-management behavior until telemetry is extended

---

## Recovery Notes

If work is interrupted:

- resume from `PadBuilder` first if Phase 4A is incomplete
- do not start `CrestDip` before `RampJump` is validated end-to-end
- do not regress `Chicane` back toward lane-shift geometry
- do not treat `Chicane` as complete based only on rendering if stronger runtime observability becomes available during the phase
- keep `Main.server.luau` baseline-only unless a later explicit plan changes that policy
