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

Phase 17 is complete locally. Current implementation includes:

- track generation and sector state management
- rollback and full-lap verification
- integrity evaluation and repair loops
- narrow LLM adapter boundary
- replicated HUD and scoring display
- local Studio-backed test workflow through `make`
- server-side LLM trace capture and JSON export
- automated endurance trace capture for model comparison

See [plans/agent-handoff.md](plans/agent-handoff.md) for the current session history and [plans/phase17.md](plans/phase17.md) for the Phase 17 trace/export plan and final scope.

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
make test TEST=phase13_unit
```

Direct targets also exist:

```sh
make phase13_unit
make phase13_integration
```

Notes:

- Studio-backed suites run sequentially against one live Studio session
- Unit-style suites automatically choose `skip_baseline` when configured
- Integration suites run against the normal baseline boot flow

## Code Hygiene

The repo now includes a deterministic Luau hygiene toolchain with pinned versions in `rokit.toml`.

Install/update pinned tools:

```sh
rokit install
```

Run commands:

```sh
make fmt
make fmt-check
make typecheck
make typecheck-report
make lint
make hygiene
```

`make hygiene` is the fast static gate (`fmt-check` + `typecheck` + `lint`) and is safe for frequent local/CI use.

Phase 30 expands `fmt` / `fmt-check` / `lint` repo-wide across tracked `.luau` source under `src/` and `studio/`.

Phase 31 makes `make typecheck` and `make typecheck-report` Roblox-aware by generating a Rojo sourcemap and using a vendored Roblox definitions file for standalone `luau-lsp analyze` runs.

`make typecheck` remains intentionally conservative and green on a documented subset while `make typecheck-report` exposes the current full-repo analyzer backlog without gating local iteration.

See `docs/code-hygiene.md` for scope, rationale, and the current typecheck boundary.

## LLM Trace Capture

The maintained local workflow for LLM transcript capture is the CLI plus Studio bridge. Full transcripts stay server-side during Play and are exported as JSON on demand.

Export the latest trace from an already running Play session:

```sh
make export-llm-trace
```

That command prints raw JSON to stdout, so it is easy to redirect to a file:

```sh
make export-llm-trace > traces/manual-session.json
```

For repeatable endurance runs, use the automated one-command workflow:

```sh
make endurance-trace MODEL=google/gemma-3-4b-it DURATION=60 OUT=traces/endurance-gemma.json
```

This command:

- starts Play through the maintained Studio bridge
- enables the LLM backend
- sets the requested model
- starts endurance mode automatically
- waits for the requested duration in seconds
- exports the latest server-side LLM trace to `OUT`
- stops the Play session

No HUD interaction is required for `make endurance-trace ...`. You do not need to run `/llm on`, `/llm model ...`, or `/demo endurance` manually.

Recommended usage:

- run one Play session per model to keep traces clean
- export before stopping Play when using `make export-llm-trace`
- keep local captures under `traces/` (already gitignored)

Examples:

```sh
make endurance-trace MODEL=google/gemma-3-4b-it DURATION=90 OUT=traces/endurance-gemma.json
make endurance-trace MODEL=qwen/qwen-turbo DURATION=90 OUT=traces/endurance-qwen.json
make endurance-trace MODEL=google/gemini-2.5-flash-lite:nitro DURATION=90 OUT=traces/endurance-gemini-flash-lite.json
```

The default `DURATION` is `60` seconds if omitted.

To inspect an exported trace as logical LLM calls instead of raw event triples:

```sh
make inspect-llm-trace TRACE=traces/endurance-gemma.json
```

That view includes the traced prompt content sent to the model:

- `system` / `user` prompt bodies for proposal and repair calls
- role-tagged orchestrator message entries for endurance decisions

To include raw response snippets as well:

```sh
make inspect-llm-trace TRACE=traces/endurance-gemma.json RAW=1
```

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
- [plans/phase17.md](plans/phase17.md): current LLM trace/export milestone plan and completion notes

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
