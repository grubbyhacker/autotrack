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
