# AutoTrack

AutoTrack is an autonomous level-design CI pipeline built inside a Roblox experience.

It is not a racing game. It is a watchable simulation of an agent modifying one straight sector of a live rectangular track, running a visible verifier lap, then deciding whether to commit, repair, or revert the change.

## What It Does

For each job, the system:

1. Parses a plain-language request such as `Add a jump in sector 3`
2. Proposes a mechanic configuration for one editable straight sector
3. Builds that geometry into the live track
4. Runs a full visible verifier lap with one car
5. Measures traversal, integrity, and challenge metrics
6. Repairs or reverts if the result is not acceptable
7. Commits the sector state if the run succeeds

Supported v1 mechanics:

- `RampJump`
- `Chicane`
- `CrestDip`

## Project Status

Phase 11 is complete locally. Current implementation includes:

- track generation and sector state management
- rollback and full-lap verification
- integrity evaluation and repair loops
- narrow LLM adapter boundary
- replicated HUD and scoring display
- local Studio-backed test workflow through `make`

See [plans/agent-handoff.md](plans/agent-handoff.md) for the current session history and [plans/phase11.md](plans/phase11.md) for the detailed Phase 11 plan and final scope.

## Repository Layout

```text
default.project.json
src/
  common/        -> ReplicatedStorage.AutoTrackCommon
  ui/            -> ReplicatedStorage.AutoTrackUI
  track/         -> ServerScriptService.AutoTrackCore.Track
  mechanics/     -> ServerScriptService.AutoTrackCore.Mechanics
  verifier/      -> ServerScriptService.AutoTrackCore.Verifier
  integrity/     -> ServerScriptService.AutoTrackCore.Integrity
  agent/         -> ServerScriptService.AutoTrackCore.Agent
  orchestrator/  -> ServerScriptService.AutoTrackCore.Orchestrator
studio/
tools/
plans/
```

## Development Model

This repo is built around Rojo and Git.

- Edit Luau source in `src/`
- Treat local files as the source of truth
- Use Roblox Studio and the bridge tooling for runtime validation
- Do not edit synced gameplay scripts directly in Studio

The canonical implementation rules are in [AGENTS.md](AGENTS.md).

## Running Tests

The maintained test path is the local CLI and Studio bridge workflow.

List available suites:

```sh
make test-list
```

Run a specific suite:

```sh
make test TEST=phase11_unit
```

Direct targets also exist:

```sh
make phase11_unit
make phase11_integration
```

Notes:

- Studio-backed suites run sequentially against one live Studio session
- Unit-style suites automatically choose `skip_baseline` when configured
- Integration suites run against the normal baseline boot flow

## Scoring

Phase 11 adds a simple challenge score breakdown to the HUD. The player-facing labels are intentionally minimal:

- `Air`
- `Lat`
- `Edge`
- `Cost`

The canonical explanation of those terms lives in [plans/adr-phase11-scoring-reporting.md](plans/adr-phase11-scoring-reporting.md).

## Key Documents

- [prd_plan.md](prd_plan.md): product requirements, schemas, and architecture
- [AGENTS.md](AGENTS.md): project rules for coding agents
- [plans/agent-handoff.md](plans/agent-handoff.md): phase status and lessons learned
- [plans/phase11.md](plans/phase11.md): current milestone plan and completion notes

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
