## Phase 12.5 — HUD/UI Readability Overhaul

### Goal

Improve the HUD without touching any simulation, physics, scoring, or verifier logic.  
Every change is cosmetic or UX-only: layout, information density, label clarity, and the new "Set Baseline" convenience button.

---

### Problem inventory

| Area | Problem | Fix |
|---|---|---|
| Repair explanation | Buried in the command input dock — not logically related to commands | Move to a dedicated "Agent Reasoning" bar below the top strip |
| Repair action text | Also in the command input dock | Move alongside the reasoning bar |
| Bottom dock | Too tall because it contains non-command content | Shrink after removing reasoning/action rows |
| Input box | Retains previous text on focus — requires manual delete | Set `ClearTextOnFocus = true` |
| Live Telemetry | "Current Speed" is two lines, verbose label | Compact to `Speed  47.3` on one line; add heading and pitch |
| Live Telemetry | No attitude/orientation info | Add `Heading  NW 312°` and `Pitch  +4°` from `car.CFrame` |
| Recent Loop | No directional hint — reader doesn't know top vs bottom is newest | Add "↑ older  newer ↓" sub-caption; entries already flow newest-at-bottom |
| Session Telemetry | Each metric uses two lines (label + value on separate lines) | Compact to single-line `Label  value` format; panel shrinks |
| Baseline | Auto-set at boot only; no way to re-capture after a good run | Add "Set Baseline" button in Session Telemetry panel |

---

### Layout blueprint

```
┌──────────────────────────────────────────────────────────────┐  TOP STRIP (74 px, unchanged)
│  Phase Label (bold 24)          ATTEMPT 3/5               │
│  Sector 3 · Chicane | full raw text                 Committed │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐  AGENT REASONING BAR (new, 56 px)
│  AGENT REASONING                                             │
│  The ramp angle was too steep; reducing to mid band.         │
│  ACTION  ramp_angle → mid                                    │
└──────────────────────────────────────────────────────────────┘

Left rail (188 px wide)                  Right rail (188 px wide)
┌─────────────────────┐                 ┌─────────────────────┐
│ LIVE TELEMETRY      │                 │ SESSION TELEMETRY   │
│ Speed    47.3 st/s  │                 │ Baseline  12.45s    │
│ Heading  NW 312°    │                 │ Last Lap  13.21s    │
│ Pitch    +4°        │                 │ Slowdown  +6%       │
│─────────────────────│                 │─────────────────────│
│ EVENT LOG  newer ↓  │                 │ Score  S3  47.2     │
│ Boot baseline done  │                 │ Air 8.2  Edge 4.1   │
│ Sector 3 entered    │                 │ Lat 6.8  Cost 1.2   │
│ Attempt 1 started   │                 │─────────────────────│
│ Lap complete: 13.2s │                 │ Track  142.3 (4 s)  │
└─────────────────────┘                 │ Budget  ██████░░64% │
                                        │─────────────────────│
                                        │  [Set Baseline Lap] │
                                        └─────────────────────┘

┌──────────────────────────────────────────────────────────────┐  BOTTOM DOCK (~72 px, shrunk)
│  COMMAND INPUT                                               │
│  [Try: Add a chicane in sector 3               ] [ Submit ] │
│  Examples: Add a jump in sector 4  |  Add a wide chicane...  │
└──────────────────────────────────────────────────────────────┘
```

---

### Deliverables

#### 1. New "Agent Reasoning" bar — `HUDRegistry.luau`

- Full-width strip between top strip and the two rails (y ≈ 100)
- Height 56 px, same amber stroke as top strip
- Two labels: `reasoningLabel` (explanation text) and `actionLabel` (repair action chip)
- Hidden / muted when both strings are empty
- Replaces the `explanationLabel` and `actionLabel` slots currently inside `bottomDock`

#### 2. Live Telemetry compaction — `HUDRegistry.luau` + `StatsPanel.luau`

- `Speed    47.3` — one line, 18 px GothamMedium
- `Heading  NW 312°` — one line; compass label derived from degrees attribute
- `Pitch    +4°` — one line; sign-formatted; shows nose-up/down feel

New helper in `StatsPanel`:
```
StatsPanel.setCurrentSpeed(speed: number)          -- already exists, reformatted
StatsPanel.setHeading(deg: number)                  -- new
StatsPanel.setPitch(deg: number)                    -- new
```

"EVENT LOG" sub-section:
- Rename label "RECENT LOOP" → "EVENT LOG"
- Add tiny sub-caption `older ↑  ↓ newer` to clarify read direction
- Entries already populate newest-at-bottom; no logic change

#### 3. Session Telemetry compaction — `HUDRegistry.luau` + `StatsPanel.luau`

Single-line format for every row:
```
Baseline   12.45s
Last Lap   13.21s
Slowdown   +6%
Score  S3  47.2
Air 8.2  Edge 4.1
Lat 6.8  Cost 1.2
Track  142.3 (4)
Budget  ██████░░  64%
```

Budget row is a pseudo-bar using block characters — no additional instance overhead.  
Overall panel height may grow slightly to accommodate all rows comfortably (~340 px).

#### 4. "Set Baseline Lap" button — all layers

**UI** (`HUDRegistry.luau`): amber-outline button at the bottom of the right rail. Enabled when `last_lap_time > 0`; disabled/dimmed otherwise.

**Client** (`HUD.client.luau`): on click, fires new RemoteEvent `AutoTrack_SetBaseline`. Observe `last_lap_time` to enable/disable the button.

**Server** (`Main.server.luau`): wire `AutoTrack_SetBaseline.OnServerEvent`. Handler reads `stateFolder:GetAttribute("last_lap_time")`. If > 0, calls `UIState.setBaselineLapTime(t)`, `RuntimeContext.setBaselineLapTime(t)`, and `workspace:SetAttribute("AutoTrack_BaselineLapTime", t)`. Appends to log: `"Baseline updated: X.Xs"`.

**UIState** (`UIState.luau`): no new function needed; `setBaselineLapTime` already exists.

#### 5. New live telemetry attributes — `UIState.luau` + `Main.server.luau`

New UIState setters:
```lua
UIState.setCarAttitude(headingDeg: number, pitchDeg: number)
  -- sets: current_heading_deg, current_pitch_deg
```

Poll loop in `Main.server.luau` (currently at `task.wait(0.1)`) extended to also compute and publish heading + pitch from `car.CFrame`:
```lua
local look = car.CFrame.LookVector
local headingDeg = (math.atan2(-look.Z, look.X) * (180 / math.pi) + 360) % 360
local pitchDeg = math.asin(math.clamp(look.Y, -1, 1)) * (180 / math.pi)
UIState.setCarAttitude(headingDeg, pitchDeg)
```

`HUD.client.luau` observes `current_heading_deg`, `current_pitch_deg`.

Compass label helper (client-side in HUD or StatsPanel):
```
NW 312° → bearingLabel = compassDir(deg) .. " " .. math.floor(deg) .. "°"
```
where `compassDir` maps 0-360 → "N/NE/E/SE/S/SW/W/NW" (8-point).

#### 6. Input box clear on focus — `HUDRegistry.luau`

Change `ClearTextOnFocus = false` → `ClearTextOnFocus = true` in `createTextBox` call for the command input.

#### 7. Bottom dock shrink — `HUDRegistry.luau`

Remove `explanationLabel` and `actionLabel` from `bottomDock`.  
Reduce `bottomDock` height from 132 → 74 px.  
Re-anchor `inputBox` and `submitButton` upward accordingly.

---

### Files changed

| File | Change |
|---|---|
| `src/ui/HUDRegistry.luau` | Full layout rebuild (all 7 items) |
| `src/ui/StatsPanel.luau` | Compact formatters, `setHeading`, `setPitch` |
| `src/ui/StatusPanel.luau` | `setExplanation`/`setRepairAction` target new `reasoningLabel`/`actionLabel` in reasoning bar |
| `src/client/HUD.client.luau` | Observe new attrs; `Set Baseline` button wiring |
| `src/orchestrator/UIState.luau` | `setCarAttitude`; new attrs `current_heading_deg`, `current_pitch_deg` |
| `src/orchestrator/Main.server.luau` | Publish heading/pitch; wire `AutoTrack_SetBaseline` event |
| `src/track/TrackVisuals.luau` | Attach `BillboardGui` sector number labels in `buildSectorShell` |
| `src/client/TrackCamera.client.luau` | Add overview mode toggle + lerp-to-overview camera; expose via BindableEvent |

---

---

### 8. Sector number labels (world-space)

Every sector needs a visible number so the HUD ("Sector 3 · Chicane") maps to something you can see on the track.

**Server-side** (`src/track/TrackVisuals.luau`): when building each sector shell, attach a `BillboardGui` to the sector's `Anchor` part:
- `Size = UDim2.new(0, 80, 0, 40)`, `StudsOffset = Vector3(0, 14, 0)`, `AlwaysOnTop = false`
- `TextLabel` with text `"S3"` (sector id), 20 px GothamBold, amber color, background transparent
- Corner sectors use muted color to distinguish from editable straights
- Already-exported `TrackVisuals.buildSectorShell` is the right insertion point

Labels stay visible in normal chase view (useful peripheral info) and become prominent in Overview mode.

---

### 9. Overview mode — full-track camera

A floating "Overview" toggle button in the HUD (top-right corner of screen, outside any panel). When pressed:
- Camera smoothly tweens to a high isometric view that fits the entire track (reuse `computeFallbackView()` logic from `TrackCamera.client.luau`)
- Sector labels read clearly from above; the verifier car is visible but small
- Normal chase/side camera loop is suspended while in overview mode
- A second press (or the same button, now labeled "Chase") returns to normal chase mode with a smooth tween back

**Implementation approach:**
- Add a `_overviewMode` boolean in `TrackCamera.client.luau` (client-local state, no server attribute needed)
- `RenderStepped` loop: if `_overviewMode`, use `computeFallbackView()` CFrame with a lerp towards it (`_overviewCFrame`); otherwise normal chase logic
- **Overview button** in `HUDRegistry.luau`: small pill button, fixed top-right (AnchorPoint 1,0), always on top (ZIndex 20)
- `HUD.client.luau` fires a `BindableEvent` (or direct module call) to toggle `_overviewMode`
- Export `TrackCamera.setOverviewMode(bool)` from the module so HUD can reach it via `ReplicatedStorage` BindableEvent or a shared module flag

**Camera target for overview:**
- Extend `computeFallbackView()` to accept an optional elevation multiplier; overview uses 1.4× height for a cleaner top-down angle
- Tween duration ≈ 0.6 s using `TweenService` on `Camera.CFrame`

**Files:**
- `src/client/TrackCamera.client.luau` — add `_overviewMode` flag, lerp-to-overview CFrame in RenderStepped, expose toggle via BindableEvent in ReplicatedStorage
- `src/ui/HUDRegistry.luau` — add `overviewButton` (ref slot added to `_refs`)
- `src/client/HUD.client.luau` — wire overview button click → fire BindableEvent

---

### Non-goals for 12.5

- No new mechanics
- No scoring changes
- No physics or verifier changes
- No session persistence
- No new external assets

---

### Test coverage

`TestPhase12_5` (smoke only, no simulation):

1. HUD mounts without error; all named ref slots present in `HUDRegistry.get()`
2. `StatsPanel.setHeading(135)` → `currentHeadingLabel.Text` contains "SE"
3. `StatsPanel.setPitch(-8)` → label contains "-8°"
4. `UIState.setCarAttitude(270, 3)` sets both attributes correctly
5. `StatusPanel.setExplanation("test")` → `reasoningLabel.Text == "test"` (not in bottomDock)
6. Input box `ClearTextOnFocus == true`
7. Set Baseline button exists in rightRail; disabled when `last_lap_time == -1`
8. `TrackVisuals.buildSectorShell` attaches a `BillboardGui` to the Anchor part; label contains the sector id
9. Overview button exists in `HUDRegistry.get()` refs; clicking it fires the BindableEvent
10. `TrackCamera` exports `setOverviewMode`; toggling it changes `_overviewMode` flag

---

### Open questions before implementation

1. **Reasoning bar always visible or slide-in?**  
   Always visible (muted/dimmed when empty) keeps layout stable. Slide-in looks better but adds tween complexity. Recommendation: always visible, dim when idle.

2. **Budget bar — block chars vs UIFrame fill?**  
   Block characters (`█░`) are zero-instance overhead but font-dependent. A thin `Frame` fill is instance-heavy but pixel-perfect. Recommendation: block chars for now, upgrade later if it looks bad.

3. **Heading degrees vs cardinal only?**  
   Both: `NW 312°`. More information, same line.

4. **Right rail height?**  
   Needs to grow from 290 → ~380 px to fit compact single-line stats + budget row + Set Baseline button. Adjust left rail to match for visual balance.
