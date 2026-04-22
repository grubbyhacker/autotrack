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

Smoke test new features before handing control back to the human.

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

### Local CLI workflow

For normal local development, prefer the checked-in terminal runner over Claude/MCP:

```sh
make boot_smoke
make phase6_integration
make phase21_unit
make refactor_fast
make test TEST=phase6_integration
```

This requires the local Studio bridge plugin from `studio/AutoTrackTestBridge.server.lua` to be installed and enabled in Studio, with localhost HTTP access allowed.

The suite/boot-mode mapping lives in `tools/test_bridge_config.json`.

This workflow is now a maintained project contract, not an optional convenience.

- New test suites must be runnable through `make`, either as `make phaseN...` or via `make test TEST=...`.
- When adding a new `TestPhaseN.luau` suite or any new targeted suite command, update all of:
  - `src/orchestrator/TestDispatcher.luau`
  - `tools/test_bridge_config.json`
  - `Makefile` if a direct target should exist
- Do not add new test flows that are only reachable through Claude/MCP unless there is a strong technical reason and that exception is documented.
- Preserve the terminal contract:
  - `make test-list` lists every supported suite
  - `make boot_smoke` is the fast startup sanity check for server boot completion
  - unit/synthetic suites choose `skip_baseline` automatically
  - integration/live-lap suites choose `baseline` automatically
- Keep the local runner sequential. Do not assume parallel `make phase...` invocations on the same Studio session are supported.
- If a future change breaks the local plugin bridge, fix that before considering the phase complete.
- Prefer this `make` path for Roblox/Studio-backed verification by default, especially for milestone-complete validation and final end-of-phase test runs.
- The bridge startup contract now includes a boot-readiness gate before suite dispatch:
  - `RuntimeContext` must be initialized
  - `ReplicatedStorage.AutoTrackUIState` must exist
  - `ReplicatedStorage.AutoTrack_SubmitRequest` must exist
  - `Workspace.Track` must exist
  - `Workspace.VerifierCar` must exist
- If this gate fails, treat it as a startup regression first, before assuming a suite-specific bug.
- It is still fine to use direct local shell commands for very small pure file/static checks that do not require Studio, such as:
  - syntax checks
  - `make test-contracts`
  - sourcemap generation
  - lint/format validation
  - listing available suites or config
- Do not route trivial non-Studio checks through the Studio bridge just for consistency.
- For finalized milestone validation, the expected path is the maintained `make` workflow rather than Claude/MCP-triggered suite execution, unless the bridge is broken and the fallback is explicitly noted.

The checked-in components for this path are:

- `Makefile`
- `tools/autotrack_test_cli.py`
- `tools/test_bridge_config.json`
- `studio/AutoTrackTestBridge.server.lua`
- `src/orchestrator/TestSession.luau`
- `src/orchestrator/TestDispatcher.luau`
- `src/orchestrator/StudioTestBootstrap.server.luau`

For Phase 1, tests also auto-run at boot end (see `Main.server.luau`). Later phases may do the same.

### HUD slash commands

The in-experience HUD command bar supports a small slash-command surface for convenience. Keep this narrow and intentional.

- Demo command shape:
  - `/demo <name>`
- Test command shape:
  - `/test <suite>`
- Tune command shape:
  - `/tune <verb>`

Current supported demo commands:

- `/demo camera`
- `/demo rampitup`
- `/demo repair`
- `/demo llmerror`
- `/demo ui-hotfix`

`/demo camera` toggles the default camera demo on and off. It exists to help evaluate spectator-camera behavior without changing the normal boot workflow. The default camera demo loops playable `RampJump` obstacles in sectors `3` and `7`.

`/demo rampitup` toggles a dedicated ramp demo on and off. It applies playable `RampJump` obstacles in sectors `3` and `8` so two working ramps can be observed in the same loop.

`/demo repair` toggles a HUD-only repair-state preview on and off. It does not modify track geometry; it only populates the top-right repair attempt UI, request context, explanation, action text, and realistic recent log lines so repair presentation can be reviewed quickly.

`/demo llmerror` toggles a HUD-only LLM warning preview on and off. It does not modify track geometry; it sets a realistic repair-context request, selects a real model id, and publishes a representative rate-limit error so the LLM warning strip above the selector can be reviewed.

`/demo ui-hotfix` toggles a HUD-only endurance-plus-hotfix preview on and off. It does not modify track geometry; it only enables the `Endurance Mode` and `Hotfix Mode` badges, sets representative endurance counters, and populates recent escalation log lines so those UI surfaces can be reviewed quickly.

`/test <suite>` is allowed as a **session-local convenience shortcut** into the existing server-side suite dispatcher. It must reuse the same suite names handled by `src/orchestrator/TestDispatcher.luau`.

`/tune ...` is the isolated single-sector mechanic workspace added in Phase 21. It owns the session while active.

Current supported tune commands:

- `/tune rampjump`
- `/tune crestdip`
- `/tune chicane`
- `/tune show`
- `/tune run <n>`
- `/tune auto <on|off>`
- `/tune set <lever> <value>`
- `/tune pad <ingress|egress> <PadValue>`
- `/tune attr <name> <value>`
- `/tune reset`
- `/tune revert`
- `/tune commit`
- `/tune stop`

Important constraints for `/tune`:

- It targets the isolated tune lane in sector `3` in Phase 21.
- It keeps the sector centered on screen and runs repeated entry-to-exit passes through that sector only.
- It now starts in staged mode by default; use `/tune run <n>` for exact multi-attempt candidate evaluation.
- `/tune auto on` restores the continuous spectator loop; `/tune auto off` returns to staged control.
- Tune mutation commands should not modify the candidate while a run batch is in flight.
- Full-lap verification is still required elsewhere for scoring and authoritative track evaluation.
- Tune-mode verifier attributes are a curated server-side whitelist. Do not add arbitrary workspace-attribute writes.
- Tune mode blocks normal submit/demo/test flows until `/tune stop`.

Important constraints for `/test`:

- It does **not** replace the maintained `make ...` workflow.
- It does **not** manage boot mode selection, baseline setup, Studio restarts, or HTTP bridge orchestration.
- It should be treated as a shortcut for a session that is already in the correct state for the requested suite.
- Final milestone validation should still use the maintained `make` path unless that path is broken and the exception is documented.

Do not reintroduce ad hoc demo/test command aliases once removed. If new slash commands are added later, document them here and keep the shape consistent with `/demo <name>` and `/test <suite>`.

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

1. `plans/agent-handoff.md` — phase completion status and current work-in-progress
2. `plans/phaseN.md` (or the current plan file) for the phase you are about to implement

If either file is missing or stale, update it before proceeding.

**Declutter task (run each session):** If `plans/agent-handoff.md` has grown beyond ~100 lines, compact it — move any new durable lessons into the "Hard-won invariants" section below, and remove historical narrative that is now reflected in code.

---

## Hard-won invariants

These were discovered during implementation and are not obvious from reading the code.

### Require paths — always use ReplicatedStorage, never relative

All modules in `src/integrity/`, `src/track/`, `src/verifier/`, `src/mechanics/`, `src/orchestrator/`, `src/agent/` must require `src/common/` via:

```lua
game:GetService("ReplicatedStorage"):WaitForChild("AutoTrackCommon"):WaitForChild("ModuleName")
```

Relative paths like `script.Parent.Parent.common.Types` silently resolve to the wrong container and only fail at runtime.

### VerifierCar must stay a single physics root

`VerifierCar` must always be a `BasePart` named `"VerifierCar"` in Workspace. Controller forces and attachments bind to that root. Visual body pieces must be welded, non-colliding, and massless. Never change the root to a Model or rename it.

### Sector folder contract

Every sector folder must contain exactly these children: `Anchor`, `Collision`, `Visual`, `Pads`. Visual changes go in `Visual`; collision geometry goes in `Collision`. Do not attach sector-level shell or visual concepts to individual mechanic parts.

### Pad semantics

Pads set the **commanded speed** when activated — they do not add a delta. The velocity snaps immediately to the new target speed. Persistence: `IngressPad` affects the current sector; `EgressPad` affects the current sector plus the next. Corner slowdown caps the target speed rather than multiplying pad-adjusted speeds.

Current pad tiers: `None`, `Boost5`, `Boost10`, `Boost25`, `Boost50`, `Brake5`, `Brake10`, `Brake25`, `Brake50`.

### `no_progress` is a speed-bleed failure, not a geometry failure

When `FailureInfo.detail == "no_progress"` on a RampJump, the car ran out of momentum going uphill. The correct repair is **ingress Boost first, then shorten the ramp** — never lengthen the ramp. Lengthening makes it worse by bleeding more momentum uphill.

Same pattern for CrestDip: boost first, then lower peak height. For Chicane: widen corridor / lengthen transitions, never reduce amplitude below the integrity floor.

### `target_exited` is required for downstream failure classification

A failure in a non-target sector is only a `downstream_failure` (repairable) if `RunMetrics.target_exited == true`. If the target was entered but not fully exited, treat it as a pre-target failure and revert immediately. Do not use `target_entered` alone for this classification.

### RampJump "looked fine but integrity failed" = reacquire failed

The RampJump has two gate conditions: (1) becomes airborne, (2) reacquires within `RAMPJUMP_REACQUIRE_MAX` studs after the gap. "Jumped cleanly but integrity failed" almost always means reacquire failed — the car overshot or landed off the landing tiles. Repair levers: shorten `gap_length` or lengthen `landing_length`.

### RampJump acceptance must include the real demo lap

A green target-sector RampJump suite is not enough to call the mechanic stable. The isolated target-sector path can pass while a committed full-lap demo still fails from entry, airborne heading, or post-landing recovery behavior.

When changing RampJump geometry, pads, or verifier stabilization, also validate the actual `/demo rampitup` preset path, not only `phase4_rampjump` / `phase15` / `phase16` target-sector checks.

### Straight-sector stabilization is intentionally stronger than corner stabilization

Non-corner straights intentionally damp yaw/roll harder and pin the car toward forward heading more aggressively than corners. This is part of the current demo-reliability contract, especially around ramps and brake-pad ingress.

Do not "simplify" this away without checking ramp demos. Preserve pitch freedom so the car can still climb ramps; the stabilization is mainly about yaw/roll control on straights.

### The verifier is guided, not a hard rail

Visible body or nose excursions do not automatically mean the controller is off the path. The important measurements are the emitted containment / path metrics, not camera intuition alone.

When debugging steering or cornering regressions, prefer the verifier's planar heading, cross-track, and containment telemetry over visual judgment from the spectator camera.

### Luau type annotation syntax

Table field assignments cannot have type annotations:
```lua
-- INVALID:
LevelMappings.NUMERIC_LEVERS: { [string]: { string } } = { ... }
-- Valid:
LevelMappings.NUMERIC_LEVERS = { ... }
```

### LapEvaluator returns two values

```lua
local result, hints = LapEvaluator.evaluate(lapFailure, state, metrics, targetSectorId)
```

Always pass `targetSectorId` (the job's intended target) as the 4th argument — not `lapFailure.sector_id` (where the car actually failed). The hints list is needed to build a meaningful `FailurePacket`.

### Rojo client sync requires Play restart

Local file edits are not live in a running Play session. Stop Play → edit → Start Play → wait for boot → test. If camera or client behavior appears unchanged, verify whether `PlayerScripts` is still serving a stale copy.

### Runtime build/profile stamps are the stale-session sanity check

The HUD/UI runtime build stamp and controller profile exist specifically to catch stale Studio sessions and mismatched client/server code. If live behavior does not match the local diff, confirm those stamps before retuning the mechanic again.

### `/demo maximize` suppresses Stage B challenge-up

`MaximizerAgent` sets `AutoTrack_MaximizeCampaignActive = true` for the full campaign. `JobRunner` skips the single-sector challenge-up loop during this flag. Do not remove this guard — Stage B inside maximize mixes escalation laps into campaign behavior and makes debugging impossible.

### HttpService Secret API

`HttpService:GetSecret()` returns a `Secret` object, not a string. Use `secret:AddPrefix("Bearer ")` — do not concatenate with `..`.

---

## Plans

Implementation plans live in `plans/` at the project root (e.g., `plans/phase5.md`). Each plan covers the deliverable, files to change, test cases, and verification steps. Plans are committed alongside code so the project is restartable from any phase.

**Plans must be written and committed to `plans/phaseN.md` before implementation begins.** Do not start writing code until the plan file exists in the repo. This is a hard requirement — a plan that only exists in Claude's plan-mode working memory is not sufficient.

When a phase completes:
1. Update `plans/agent-handoff.md` with the phase completion status and lessons learned
2. Ensure `plans/phaseN.md` reflects the final state (update if the plan deviated during implementation)
