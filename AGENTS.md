# AutoTrack — Coding Agent Guide

## Project summary

AutoTrack is an **Autonomous Level-Design CI Pipeline** running inside a Roblox experience. It is not a racing game. It is a watchable simulation of a propose → build → verify → repair → commit/revert loop performed by an AI agent on a live rectangular track, one straight sector at a time.

See `prd_plan.md` for the full authoritative PRD, schema contracts, mechanic specs, and build order.

---

## Authority boundaries — read this first

You are working in a **Rojo + Git environment**. Every script change MUST be made to the local files in `/src`. Do not use the MCP server to create or edit scripts directly in Roblox Studio, as Rojo will immediately overwrite those changes.

### 1. The Git/Rojo Authority (Local Files Only)

- All Luau logic, state machines, and schemas must be written to `/src`.
- Rojo is actively syncing `/src` to `ServerScriptService.AutoTrackCore`.
- The Rojo project file (`default.project.json`) is the source of truth for how `/src` maps into the DataModel.

### 2. The MCP Authority (Live Workspace Only)

- Use the MCP server exclusively for **physical world manipulation**: spawning the track parts, managing the verifier car `BasePart`, and scaling sector geometry instances.
- Use the MCP to **inspect** the DataModel (e.g., reading car velocity or finding failure coordinates) to generate telemetry for the repair loop.
- Do not use the MCP to read scripts you already have access to in the local filesystem.

### 3. Token Efficiency

- Do not use the MCP to "read" scripts you already have access to in the local filesystem.
- Perform bulk file creation in the local directory rather than individual `createInstance` calls via MCP for logic.

---

## Rojo project layout

```
default.project.json
src/
  common/          → ReplicatedStorage.AutoTrackCommon
  ui/              → ReplicatedStorage.AutoTrackUI
  track/           → ServerScriptService.AutoTrackCore.Track
  mechanics/       → ServerScriptService.AutoTrackCore.Mechanics
  verifier/        → ServerScriptService.AutoTrackCore.Verifier
  integrity/       → ServerScriptService.AutoTrackCore.Integrity
  agent/           → ServerScriptService.AutoTrackCore.Agent
  orchestrator/    → ServerScriptService.AutoTrackCore.Orchestrator
```

---

## Build order (from PRD §17)

Implement in this order — do not skip phases:

| Phase | Deliverable |
|-------|-------------|
| 1 | Track generator, fixed corners, numbered editable straights, global job lock, baseline lap scaffold |
| 2 | Sector registry, serializer, applier, rollback |
| 3 | Verifier car, semi-rail controller, failure termination, reacquire detection |
| 4 | RampJump, Chicane, CrestDip builders + PadBuilder |
| 5 | Metrics collection and mechanic integrity evaluators |
| 6 | CI orchestrator state machine (no LLM) |
| 7 | LLM adapter (narrow boundary, swappable) |
| 8 | UI layer |

**Start with a no-LLM vertical slice** (PRD §19). Hardcode one parsed request, one initial proposal, one repair policy. Prove physics/rollback/geometry before connecting a model.

---

## Key constraints

- **One verifier car**. One live track. One running job at a time.
- **Only straight sectors are editable** in v1. Corners are fixed.
- Repair loop: up to **5 repair attempts** after the initial proposal. Each repair may change **exactly one lever**.
- Locality rule: a job may only mutate the targeted straight sector. Never corners, neighboring sectors, topology, or entry/exit transforms.
- Verification is always **full-lap**, even when the edit is local.
- Verifier is **guided, not pinned** (semi-rail). Meaningful failures must be possible.
- The visible simulation is the real deciding simulation — no hidden reruns.

---

## Supported mechanics (v1)

- `RampJump` — geometry-only jump (ramp_angle, ramp_length, gap_length, landing_length, ingress/egress pads)
- `Chicane` — S-curve (amplitude, transition_length, corridor_width, ingress/egress pads)
- `CrestDip` — vertical crest or dip (height_or_depth, radius, sector_length, ingress/egress pads)

Do not invent new mechanics. Do not expand scope to multiplayer, queues, or hidden verification.

---

## Schema contracts

All structured data must conform to the schemas in PRD §15. Key types:

- `Request` — parsed user intent
- `SectorState` — current geometry + pads for one sector (versioned)
- `AgentAction` — either `SetNumericLever` or `SetPad`
- `RunResult` — simulation outcome with metrics
- `FailurePacket` — everything the agent needs for one repair step
- `CIJob` — full job record with attempt history

Keep these contracts explicit in code. Fail fast on invalid agent output or invalid request parsing.

---

## Coding rules

- Fail fast on bad input — don't silently degrade.
- No hidden state: all sector mutations go through `SectorApplier`; all reverts go through `SectorRollback`.
- The `LLMAdapter` is a narrow, swappable boundary. No LLM calls should appear outside it.
- Short explanations only in the UI (e.g., `"Entry speed too high; added ingress brake"`). No long reasoning traces.
- Pads have three values: `None`, `Boost`, `Brake`. No numeric magnitudes. No stacking.
- Session state is ephemeral — no cross-session persistence in v1.

---

## Testing philosophy

**Tests ship with each phase — never after.**

Every phase must include a `TestPhaseN.luau` module (in `src/orchestrator/`) with named assertions that cover the phase deliverable. The test suite must pass before the phase is considered complete.

### Verification approach

`execute_luau` runs **client-side** in the Studio MCP context. The test pipeline is:

1. Claude triggers via `execute_luau`:
   ```lua
   game.ReplicatedStorage:WaitForChild("AutoTrack_TestCmd", 5):FireServer("phaseN")
   ```
2. `TestRunner.server.luau` (in `ServerScriptService.AutoTrackCore.Orchestrator`) receives the RemoteEvent and dispatches.
3. Tests print structured lines: `[TEST PASS: name]` / `[TEST FAIL: name] reason`.
4. Claude reads results with `get_console_output`.

**No screen capture. No mouse. No UI reading.** All verification is through console output.

For Phase 1, tests also auto-run at boot end (see `Main.server.luau`). Later phases may do the same.

### Trace hooks

The verifier emits structured trace lines parseable by tests:

```
[TRACE] lap_start
[TRACE] sector_enter 2 speed=40.5
[TRACE] sector_exit 2 speed=38.1
[TRACE] lap_complete 25.01
[TRACE] apply sector=2 mechanic=RampJump
[TRACE] clear sector=2
[TRACE] revert sector=2
```

Tests can assert on the presence/absence and ordering of these lines. New trace points should be added whenever a phase introduces a new verifiable event.

### Test file locations

Test modules live in `src/orchestrator/` (alongside `Main.server.luau`). This is a workaround for a Rojo sync issue with new top-level directories; revisit when that is resolved.

- `TestUtils.luau` — shared `T.pass / T.fail / T.expect`
- `TestPhase1.luau` — Phase 1 assertions
- `TestPhaseN.luau` — one file per phase, added when the phase is built
- `TestRunner.server.luau` — RemoteEvent dispatcher; add each new phase with `if cmd == "phaseN" then`

### Stub / API-driven stimulation

To test code paths that would normally be triggered by LLM output or user input, call the relevant module directly from the test. Do not simulate UI clicks or player input. For example, to test `SectorApplier.apply`, construct a `SectorState` table inline and call `apply()` — then inspect workspace to confirm geometry changed.

---

## Plans

Implementation plans live in `plans/` at the project root (e.g., `plans/phase2.md`). Each plan covers the deliverable, files to change, test cases, and verification steps. Plans are committed alongside code so the project is restartable from any phase.
