# Phase 2 — Sector Package Model

## Deliverable

One sector can be replaced deterministically from schema data and reverted fully.
No mechanics yet — flat sectors only. Mechanics dispatch shell is wired but errors (Phase 4).

---

## Files to change

| File | Action |
|------|--------|
| `src/track/SectorSerializer.luau` | Implement `clone()` + `toTable()` |
| `src/track/SectorApplier.luau` | Implement `clear()` + `apply()` |
| `src/verifier/VerifierController.luau` | Add sector entry/exit trace hooks |
| `src/orchestrator/Main.server.luau` | Add `[TRACE] lap_start` / `lap_complete` prints |
| `src/orchestrator/TestPhase2.luau` | New — Phase 2 test suite |
| `src/orchestrator/TestRunner.server.luau` | Add `phase2` dispatch branch |

`src/track/SectorRollback.luau` is already complete — no changes.

---

## Implementation

### SectorSerializer.luau

**`clone(state)`** — deep-copy: copy all scalar fields, create fresh `params` and `pads` tables.

```luau
function SectorSerializer.clone(state)
    local params = {}
    for k, v in pairs(state.params) do params[k] = v end
    return {
        sector_id = state.sector_id,
        mechanic  = state.mechanic,
        params    = params,
        pads      = { ingress = state.pads.ingress, egress = state.pads.egress },
        version   = state.version,
    }
end
```

**`toTable(state)`** — identical structure as `{[string]: any}`, same copy pattern.

### SectorApplier.luau

**`clear(sector_id)`**
1. Find `workspace.Track["Sector_NN"]` (zero-padded: `string.format("Sector_%02d", sector_id)`).
2. Assert the folder exists.
3. Destroy every child whose name is NOT `string.format("Sector_%02d_Straight", sector_id)`.
4. Print `[TRACE] clear sector=N`.

**`apply(state, entryFrame, exitFrame)`**
1. Call `clear(state.sector_id)`.
2. If `state.mechanic == nil`: print `[TRACE] apply sector=N mechanic=flat` and return.
3. Otherwise dispatch:
   - `"RampJump"` → `RampJumpBuilder.build(...)` (errors until Phase 4)
   - `"Chicane"` → `ChicaneBuilder.build(...)`
   - `"CrestDip"` → `CrestDipBuilder.build(...)`
   - unknown → `error("unknown mechanic: " .. state.mechanic)`
4. Then: `PadBuilder.applyPads(state.pads, entryFrame, exitFrame)` (errors until Phase 4).
5. Print `[TRACE] apply sector=N mechanic=M`.

### VerifierController.luau — sector entry/exit traces

The waypoint list has a known structure (see TrackGenerator):
- Corners: 3 waypoints (entry, arc mid, exit)
- Straights: 2 waypoints (mid, exit)
- Final lap-close waypoint

Pass a `sectors` table (same as from `TrackGenerator.generate`) into `runLap` so it can map
waypoint transitions to sector IDs and emit:

```
[TRACE] lap_start
[TRACE] sector_enter N speed=S
[TRACE] sector_exit N speed=S
[TRACE] lap_complete T
```

Alternatively, attach `SectorId` as an attribute on each waypoint CFrame (not possible — CFrames
are values) or build a parallel `waypointToSector` lookup table in the controller.

**Simpler approach**: extend `runLap` signature to accept an optional `onSectorChange(id, entering)`
callback. `Main.server.luau` passes a callback that prints the trace lines. This keeps the
controller decoupled from printing.

### Main.server.luau — trace wiring

```luau
local function onSectorChange(id, entering)
    if entering then
        print(string.format("[TRACE] sector_enter %d speed=%.1f", id, car.AssemblyLinearVelocity.Magnitude))
    else
        print(string.format("[TRACE] sector_exit %d speed=%.1f", id, car.AssemblyLinearVelocity.Magnitude))
    end
end
print("[TRACE] lap_start")
VerifierController.runLap(car, waypoints, sectors, onSectorChange)
```

---

## TestPhase2.luau — test cases

```
serializer_clone_independent   mutate clone.params, original.params unchanged
serializer_clone_fields        cloned state has correct sector_id, mechanic, version
serializer_to_table_fields     toTable result has all required keys
applier_clear_leaves_baseline  after clear(2), Sector_02 folder has exactly 1 child
applier_apply_flat_noop        apply(flat_state, ...) leaves 1 child in Sector_02
rollback_restores_state        apply modified flat state, revert, re-apply original matches
trace_lap_start                console contains "[TRACE] lap_start" after a lap run
trace_sector_enter             console contains "[TRACE] sector_enter 2" for straight sector
trace_lap_complete             console contains "[TRACE] lap_complete"
```

Tests for `applier_clear` and `applier_apply` inspect `workspace.Track.Sector_02:GetChildren()`
before and after the call. No MCP needed — pure Luau from server context.

For rollback test: use `SectorSerializer.clone` to snapshot sector 2, apply the same flat state
(no change), then `SectorRollback.revert(2, entry, exit)`, then compare via `SectorSerializer.toTable`.

For trace tests: trace lines are already in the console from the boot lap. Check that
`workspace:GetAttribute("AutoTrack_ConsoleTrace")` is set, OR parse the in-memory trace log
(see below).

### In-memory trace log

Add a `Tracer.luau` module (in `src/orchestrator/`) that both prints and appends to a server-side
table. Tests can call `Tracer.getLog()` to inspect trace lines without re-parsing the console.

```luau
-- Tracer.luau
local _log = {}
local Tracer = {}
function Tracer.log(line) print("[TRACE] " .. line); table.insert(_log, line) end
function Tracer.getLog() return _log end
function Tracer.clear() _log = {} end
return Tracer
```

---

## Verification steps

1. Stop/start Play in Studio.
2. Wait for `[AutoTrack] Baseline lap complete` in console.
3. Trigger Phase 2 suite:
   ```lua
   game.ReplicatedStorage:WaitForChild("AutoTrack_TestCmd", 5):FireServer("phase2")
   ```
4. Read console — expect all `[TEST PASS]` lines and `[TEST] Suite done: phase2`.
5. Spot-check: `[TRACE] sector_enter 2` and `[TRACE] lap_complete` visible in console from boot lap.

---

## Notes

- The mechanic dispatch shell in `apply()` will error if called with a non-nil mechanic until Phase 4 builders are implemented. This is correct fail-fast behavior.
- `SectorRollback.revert` is already implemented and calls `SectorApplier.apply` — it will work once `apply` is implemented.
- Sector entry/exit CFrames for test calls: use `TrackGenerator.generate()` to get them at test time.
