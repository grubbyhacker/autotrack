# Phase 4 — Mechanic Builders

## Deliverable

All three mechanic builders (RampJump, Chicane, CrestDip) and PadBuilder fully implemented. `SectorApplier.apply()` no longer errors for any mechanic. Any legal `SectorState` can be rendered deterministically.

---

## Files to create/modify

| File | Action |
|------|--------|
| `src/mechanics/PadBuilder.luau` | Implement stub |
| `src/mechanics/RampJumpBuilder.luau` | Implement stub |
| `src/mechanics/CrestDipBuilder.luau` | Implement stub |
| `src/mechanics/ChicaneBuilder.luau` | Implement stub |
| `src/track/SectorApplier.luau` | Pass `sector_id` as 4th arg to `applyPads` |
| `src/orchestrator/TestPhase4.luau` | New test suite |
| `src/orchestrator/TestRunner.server.luau` | Add `phase4` dispatch branch |

---

## Coordinate convention

All builders receive `entryFrame: CFrame` and `exitFrame: CFrame` from `SectorApplier`. The entry frame is the local origin for all geometry:

- `worldCF = entryFrame * localOffset`
- Local `+Z` = forward (car travel direction = `entryFrame.LookVector`)
- Local `+Y` = up (`entryFrame.UpVector`)
- Local `+X` = right (`entryFrame.RightVector`)
- `entryFrame.Position.Y` = track center Y = `TRACK_THICKNESS / 2 = 1`

---

## Shared helpers (copy into each builder file)

```lua
local function getSectorFolder(sector_id: number): Folder
    local name = string.format("Sector_%02d", sector_id)
    local track = workspace:FindFirstChild("Track")
    local folder = track and track:FindFirstChild(name)
    assert(folder, "getSectorFolder: not found: " .. name)
    return folder :: Folder
end

local function makePart(name: string, size: Vector3, cf: CFrame,
        color: BrickColor, parent: Instance): Part
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

---

## SectorApplier.luau change

One-line change — pass `state.sector_id` to `applyPads`:

```lua
-- Before:
PadBuilder.applyPads(state.pads, entryFrame, exitFrame)
-- After:
PadBuilder.applyPads(state.pads, entryFrame, exitFrame, state.sector_id)
```

---

## PadBuilder.luau

**Signature**: `applyPads(pads: Pads, ingressFrame: CFrame, egressFrame: CFrame, sector_id: number)`

```lua
function PadBuilder.applyPads(pads, ingressFrame, egressFrame, sector_id)
    local folder = getSectorFolder(sector_id)

    -- Clear stale pads
    for _, child in ipairs(folder:GetChildren()) do
        if child.Name == "IngressPad" or child.Name == "EgressPad" then
            child:Destroy()
        end
    end

    local padSize = Vector3.new(Constants.TRACK_WIDTH, 0.2, 4)
    local yOff = Constants.TRACK_THICKNESS * 0.5 + 0.1   -- just above track surface

    local function makePadPart(name, padValue, frame)
        if padValue == "None" then return end
        local p = Instance.new("Part")
        p.Name = name
        p.Size = padSize
        p.CFrame = frame * CFrame.new(0, yOff, 0)
        p.Anchored = true
        p.CanCollide = false
        p.Transparency = 0.5
        p.BrickColor = padValue == "Boost"
            and BrickColor.new("Bright green")
            or  BrickColor.new("Bright red")
        p:SetAttribute("PadType", padValue)
        p.Parent = folder
    end

    makePadPart("IngressPad", pads.ingress, ingressFrame)
    makePadPart("EgressPad",  pads.egress,  egressFrame)
end
```

---

## RampJumpBuilder.luau

**Params**: `ramp_angle` (°), `ramp_length` (horizontal studs), `gap_length`, `landing_length`.

**Derived values**:

```lua
local angleRad    = math.rad(p.ramp_angle)
local rampH       = p.ramp_length * math.tan(angleRad)         -- height gained
local rampSurfLen = p.ramp_length / math.cos(angleRad)         -- part length along surface
local totalHoriz  = p.ramp_length + p.gap_length + p.landing_length
assert(totalHoriz <= Constants.STRAIGHT_LENGTH,
    "RampJumpBuilder: geometry exceeds STRAIGHT_LENGTH (" .. totalHoriz .. ")")
```

**Parts**:

```lua
local W = Constants.TRACK_WIDTH
local T = Constants.TRACK_THICKNESS
local folder = getSectorFolder(state.sector_id)

-- Ramp: tilted nose-up, center at (0, rampH/2, ramp_length/2) in local frame
-- CFrame.Angles(-angleRad, 0, 0) rotates the part's Z-axis upward
local rampCF = entryFrame
    * CFrame.new(0, rampH / 2, p.ramp_length / 2)
    * CFrame.Angles(-angleRad, 0, 0)
makePart("Ramp", Vector3.new(W, T, rampSurfLen),
    rampCF, BrickColor.new("Bright orange"), folder)

-- Landing: flat at track level after the gap
local landZ = p.ramp_length + p.gap_length + p.landing_length / 2
local landCF = entryFrame * CFrame.new(0, 0, landZ)
makePart("Landing", Vector3.new(W, T, p.landing_length),
    landCF, BrickColor.new("Dark stone grey"), folder)
```

The gap (between ramp top and landing) is empty air — no part needed.

---

## CrestDipBuilder.luau

**Params**: `height_or_depth` (pos = crest, neg = dip), `radius` (reserved for integrity checks), `sector_length`.

```lua
local h       = p.height_or_depth
local L       = p.sector_length
local halfL   = L / 2
local absH    = math.abs(h)
assert(L <= Constants.STRAIGHT_LENGTH,
    "CrestDipBuilder: sector_length exceeds STRAIGHT_LENGTH")

local rampAngle  = math.atan(absH / halfL)
local rampSurf   = halfL / math.cos(rampAngle)
local partSize   = Vector3.new(Constants.TRACK_WIDTH, Constants.TRACK_THICKNESS, rampSurf)
local color      = BrickColor.new("Medium stone grey")
local folder     = getSectorFolder(state.sector_id)

if h >= 0 then
    -- Crest: up-ramp then down-ramp, peak at center
    -- Part A rises: center at (0, h/2, halfL/2), nose-up tilt
    local cfA = entryFrame
        * CFrame.new(0, h / 2, halfL / 2)
        * CFrame.Angles(-rampAngle, 0, 0)
    -- Part B descends: center at (0, h/2, halfL + halfL/2), nose-down tilt
    local cfB = entryFrame
        * CFrame.new(0, h / 2, halfL + halfL / 2)
        * CFrame.Angles(rampAngle, 0, 0)
    makePart("CrestUp",   partSize, cfA, color, folder)
    makePart("CrestDown", partSize, cfB, color, folder)
else
    -- Dip: down-ramp then up-ramp, valley at center
    -- h is negative, so h/2 offsets downward
    local cfA = entryFrame
        * CFrame.new(0, h / 2, halfL / 2)
        * CFrame.Angles(rampAngle, 0, 0)
    local cfB = entryFrame
        * CFrame.new(0, h / 2, halfL + halfL / 2)
        * CFrame.Angles(-rampAngle, 0, 0)
    makePart("DipDown", partSize, cfA, color, folder)
    makePart("DipUp",   partSize, cfB, color, folder)
end
```

---

## ChicaneBuilder.luau

**Params**: `amplitude` (AMP, lateral offset studs), `transition_length` (TL, horizontal length per diagonal), `corridor_width` (reserved for integrity checks).

**Layout** (7 segments, viewed from above; all at local Y=0):

```
Z=0                          Z=40+3*TL
[Entry]-[Diag1→]-[Corr1]-[Diag2←]-[Corr2]-[Diag3→]-[Exit]
   X=0    X=0→AMP   X=AMP  X=AMP→-AMP X=-AMP X=-AMP→0  X=0
```

Assert: `40 + 3 * p.transition_length <= Constants.STRAIGHT_LENGTH`

```lua
local AMP = p.amplitude
local TL  = p.transition_length
local W   = Constants.TRACK_WIDTH
local T   = Constants.TRACK_THICKNESS
local SL  = 10  -- short straight length
local color  = BrickColor.new("Bright blue")
local folder = getSectorFolder(state.sector_id)

assert(40 + 3 * TL <= Constants.STRAIGHT_LENGTH,
    "ChicaneBuilder: geometry exceeds STRAIGHT_LENGTH (" .. (40 + 3*TL) .. ")")

-- Diagonal lengths
local diagLen  = math.sqrt(TL^2 + AMP^2)
local diag2Len = math.sqrt(TL^2 + (2*AMP)^2)

-- Yaw angles (rotation around Y)
local yaw1 = math.atan(AMP / TL)       -- Diag1 and Diag3: AMP offset
local yaw2 = math.atan(2*AMP / TL)     -- Diag2: crosses 2*AMP

local function straight(name, cx, cz, len)
    makePart(name, Vector3.new(W, T, len),
        entryFrame * CFrame.new(cx, 0, cz), color, folder)
end

local function diag(name, cx, cz, dlen, yaw)
    makePart(name, Vector3.new(W, T, dlen),
        entryFrame * CFrame.new(cx, 0, cz) * CFrame.Angles(0, -yaw, 0),
        color, folder)
end

-- Segment Z start positions
local z1 = SL                   -- after entry straight
local z2 = z1 + TL              -- after Diag1
local z3 = z2 + SL              -- after Corr1
local z4 = z3 + TL              -- after Diag2
local z5 = z4 + SL              -- after Corr2
local z6 = z5 + TL              -- after Diag3

straight("ChicEntry",  0,      SL/2,              SL)
diag    ("ChicDiag1",  AMP/2,  z1 + TL/2,         diagLen,  yaw1)
straight("ChicCorr1",  AMP,    z2 + SL/2,         SL)
diag    ("ChicDiag2",  0,      z3 + TL/2,         diag2Len, yaw2)   -- crosses center
straight("ChicCorr2", -AMP,    z4 + SL/2,         SL)
diag    ("ChicDiag3", -AMP/2,  z5 + TL/2,         diagLen, -yaw1)
straight("ChicExit",   0,      z6 + SL/2,         SL)
```

**Note on rotation signs**: `CFrame.Angles(0, -yaw, 0)` rotates the part's Z-axis toward +X (right shift). `CFrame.Angles(0, yaw, 0)` shifts toward -X (left). The sign convention must be validated in Studio — flip signs if parts appear mirrored. The invariant: `ChicDiag1` shifts track center from X=0 to X=AMP, `ChicDiag2` crosses back from X=AMP to X=-AMP.

---

## TestPhase4.luau

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackGenerator  = require(script.Parent.Parent.Track.TrackGenerator)
local SectorApplier   = require(script.Parent.Parent.Track.SectorApplier)
local PadBuilder      = require(script.Parent.Parent.Mechanics.PadBuilder)
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
```

Helper:

```lua
local function getFrames(id)
    local sectors = TrackGenerator.generate()
    for _, s in ipairs(sectors) do
        if s.id == id then return s.entry, s.exit end
    end
    error("sector not found: " .. id)
end

local function childCount(sectorId)
    local name = string.format("Sector_%02d", sectorId)
    local folder = workspace:FindFirstChild("Track")
        and workspace.Track:FindFirstChild(name)
    return folder and #folder:GetChildren() or 0
end
```

Default test states:

```lua
local RAMP_STATE = { sector_id=2, mechanic="RampJump",
    params={ramp_angle=20, ramp_length=12, gap_length=8, landing_length=12},
    pads={ingress="None", egress="None"}, version=1 }

local CHIC_STATE = { sector_id=2, mechanic="Chicane",
    params={amplitude=6, transition_length=15, corridor_width=16},
    pads={ingress="None", egress="None"}, version=1 }

local CREST_STATE = { sector_id=2, mechanic="CrestDip",
    params={height_or_depth=4, radius=10, sector_length=60},
    pads={ingress="None", egress="None"}, version=1 }
```

Eight tests:

| # | Name | How |
|---|------|-----|
| 1 | `rampjump_builds_parts` | `apply(RAMP_STATE, ...)` → `childCount(2) > 1` |
| 2 | `rampjump_has_ramp_part` | `Sector_02:FindFirstChild("Ramp") ~= nil` |
| 3 | `chicane_builds_parts` | `apply(CHIC_STATE, ...)` → `childCount(2) > 1` |
| 4 | `crestdip_builds_parts` | `apply(CREST_STATE, ...)` → `childCount(2) > 1` |
| 5 | `pad_boost_creates_part` | `PadBuilder.applyPads({ingress="Boost",egress="None"}, e, x, 2)` → 1 child with `PadType` attribute |
| 6 | `pad_none_creates_no_part` | `applyPads({ingress="None",egress="None"}, ...)` → 0 children with `PadType` |
| 7 | `rollback_after_rampjump` | `apply(RAMP_STATE)`, then `clear(2)` → `childCount(2) == 1` |
| 8 | `all_mechanics_fit_sector` | Assert ramp_total, chicane_total, crest sector_length all ≤ 120 |

Test 5: get pad count by iterating `folder:GetChildren()` and checking `:GetAttribute("PadType") ~= nil`.

### TestRunner.server.luau

Add:
```lua
elseif cmd == "phase4" then
    require(script.Parent.TestPhase4).run()
```

---

## Test pass criteria

| Test | Pass condition |
|------|---------------|
| `rampjump_builds_parts` | `childCount(2) > 1` after RampJump apply |
| `rampjump_has_ramp_part` | `Sector_02:FindFirstChild("Ramp") ~= nil` |
| `chicane_builds_parts` | `childCount(2) > 1` after Chicane apply |
| `crestdip_builds_parts` | `childCount(2) > 1` after CrestDip apply |
| `pad_boost_creates_part` | Exactly 1 child with `PadType` attribute |
| `pad_none_creates_no_part` | 0 children with `PadType` attribute |
| `rollback_after_rampjump` | `childCount(2) == 1` after `SectorApplier.clear(2)` |
| `all_mechanics_fit_sector` | All computed totals ≤ `STRAIGHT_LENGTH` (120) |

---

## Verification steps

1. Start Play, await `[AutoTrack] Baseline lap complete`.
2. `FireServer("phase4")` — expect 8 `[TEST PASS]` lines and `[TEST] Suite done: phase4`.
3. Inspect `workspace.Track.Sector_02` in Studio Explorer: should show "Ramp" + "Landing" (orange + grey).
4. Regression: run `FireServer("phase2")` and `FireServer("phase3")` — all must still pass.
5. Optional visual check: with a RampJump applied to sector 2, start Play and confirm car visually goes airborne over the ramp.

---

## Notes

- The `radius` param in CrestDip is intentionally unused in Phase 4 geometry (kept for Phase 5 integrity evaluators).
- The `corridor_width` param in Chicane is intentionally unused in Phase 4 (geometry uses full TRACK_WIDTH; used for Phase 5 integrity).
- ChicaneBuilder diagonal rotation signs must be validated in Studio — the mathematical direction depends on Roblox's Y-axis rotation convention. If parts appear mirrored horizontally, flip the sign of `yaw` on Diag1/Diag3.
