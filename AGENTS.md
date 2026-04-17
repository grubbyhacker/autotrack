# AutoTrack — Coding Agent Guide

## Project summary

AutoTrack is an **Autonomous Level-Design CI Pipeline** running inside a Roblox experience. It is not a racing game. It is a watchable simulation of a propose → build → verify → repair → commit/revert loop performed by an AI agent on a live rectangular track, one straight sector at a time.

See `prd_plan.md` for the full authoritative PRD, schema contracts, mechanic specs, and build order.

See `plans/agent-handoff.md` for **phase completion status and lessons learned** from every previous agent session. Read this before starting any work.

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

### Sector completeness invariant

When a mechanic builder does not consume the full straight-sector length, it must still leave a continuous drivable path to the sector boundary.

- Do not end authored geometry early and leave empty space to the corner.
- If a mechanic intentionally includes a gap, the gap must be the designed obstacle and the sector must still include a valid landing/rejoin path afterward.
- Future builder changes should add or preserve an explicit exit/runout segment when the authored obstacle ends before `Constants.STRAIGHT_LENGTH`.
- Tests should assert this directly for any mechanic whose geometry occupies less than the full sector.

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

### Fast inner-loop workflow

When iterating on a specific test or mechanic slice, the automatic boot baseline lap can be skipped to avoid paying the full startup lap time on every run.

- In edit mode before starting Play, set:
  ```lua
  workspace:SetAttribute("AutoTrack_SkipBootBaseline", true)
  ```
- `Main.server.luau` will then skip the automatic flat baseline lap and set:
  - `AutoTrack_BootBaselineSkipped = true`
  - `AutoTrack_BaselineLapDone = false`
  - `AutoTrack_BaselineLapTime = -1`
- Targeted test suites that understand this mode should proceed without blocking on baseline completion.

For normal full validation, leave `AutoTrack_SkipBootBaseline` unset or `false`.

### Phase 4 targeted suites

Phase 4 supports narrower commands in `TestRunner.server.luau` so mechanics can be tested independently:

- `phase4` — full sequential Phase 4 suite
- `phase4_pads` — pads only
- `phase4_rampjump` — RampJump only
- `phase4_crestdip` — CrestDip only
- `phase4_chicane` — Chicane only

Trigger them the same way as other suites:

```lua
game.ReplicatedStorage:WaitForChild("AutoTrack_TestCmd", 5):FireServer("phase4_rampjump")
```

Do not fire multiple targeted suites back-to-back on the same live sector at the same time. Run them sequentially.

### Rojo / Play-mode rule

Do not assume local file edits are live in a currently running Play session.

Safe workflow:

1. Edit local files in `/src`
2. Stop Play
3. Start Play again
4. Wait for the desired boot mode (`AutoTrack_SkipBootBaseline` or normal boot)
5. Trigger the target test suite
6. Stop Play again after validation

Use this especially when changing test modules, builders, or verifier logic.

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

## Agent startup checklist

**Read these two files at the start of every session before touching any code:**

1. `plans/agent-handoff.md` — phase completion status, lessons learned, and what the next phase needs to know
2. `plans/phaseN.md` where N is the phase you are about to implement — the detailed plan

If either file is missing or stale, update it before proceeding.

---

## Plans

Implementation plans live in `plans/` at the project root (e.g., `plans/phase5.md`). Each plan covers the deliverable, files to change, test cases, and verification steps. Plans are committed alongside code so the project is restartable from any phase.

**Plans must be written and committed to `plans/phaseN.md` before implementation begins.** Do not start writing code until the plan file exists in the repo. This is a hard requirement — a plan that only exists in Claude's plan-mode working memory is not sufficient.

When a phase completes:
1. Update `plans/agent-handoff.md` with the phase completion status and lessons learned
2. Ensure `plans/phaseN.md` reflects the final state (update if the plan deviated during implementation)
