# AutoTrack

AutoTrack is an autonomous level-design CI pipeline running inside a Roblox experience. It is a watchable simulation of agents designing obstacles on a live rectangular track, validating them with one visible verifier car, and committing only the changes that survive the real simulation.

## Endurance Mode

Endurance mode is the main experience. It continuously improves a single live track by choosing one editable straight sector at a time, adding or replacing an obstacle, testing it, repairing it when possible, and then either committing or reverting the result.

The objective is not "finish a race." The objective is to raise the committed track score while keeping the full-lap slowdown inside budget. The system treats committed full-lap results as authority: isolated checks are useful for fast vetting, but the track budget and HUD summary come from committed laps.

Each endurance build follows the same visible loop:

1. Pick a target straight sector and mechanic.
2. Build a proposed `RampJump`, `Chicane`, or `CrestDip`.
3. Run repeated isolated sector checks for endurance-origin jobs.
4. Run a full commit lap with the real verifier car.
5. Repair from structured failure telemetry, or revert if the proposal cannot be saved.
6. Commit successful geometry and update score, budget, memory, and HUD telemetry.

The three LLM-facing agents are deliberately narrow:

- **Orchestrator agent**: the chief circuit designer. It sees the whole committed track, recent outcomes, budget pressure, score history, and endurance memory. It chooses the next sector and mechanic, or decides the track is ready for the continuous loop.
- **Proposal agent**: the sector designer. It receives the orchestrator's structured `DesignIntent` and turns it into a complete `SectorState` for one sector only.
- **Repair agent**: the failure specialist. It receives a `FailurePacket`, attempt history, the original design intent, and repair memory. It returns a bounded repair while preserving as much challenge as the failure evidence allows.

There is also a hotfix path for already-committed sectors that start failing later. Hotfix is a safety path for endurance reliability, not a fourth planning role.

## What Is Editable

AutoTrack has one live track, one verifier car, and one active job at a time. Only straight sectors are editable; corners, topology, and neighboring sectors are fixed.

Supported mechanics:

- `RampJump`: ramp, gap, landing, and recovery path.
- `Chicane`: S-curve with lateral displacement and corridor width.
- `CrestDip`: vertical crest or dip with curvature constraints.

Pads can be placed at sector ingress or egress. Pad values are discrete speed commands such as `Boost10` or `Brake25`, not arbitrary numeric tuning knobs.

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
studio/          -> local Studio bridge plugin source
tools/           -> test bridge, trace tools, static checks
plans/           -> implementation history and durable handoff notes
```

This is a Rojo + Git project. Edit Luau source in `src/`; Roblox Studio receives those files through Rojo sync. Do not edit synced gameplay scripts directly in Studio.

## Makefile Workflow

Install the pinned local tools:

```sh
rokit install
```

Install the Studio bridge plugin:

```sh
make install-test-bridge-plugin
```

Restart Roblox Studio after installing or updating the plugin. The bridge is what lets terminal commands start Play, wait for boot readiness, run server-side suites, export traces, and stop Play.

Useful commands:

```sh
make test-list
make boot_smoke
make refactor_fast
make mechanics_regression
make test TEST=mechanics_regression
make hygiene
```

`make hygiene` runs the static gate: format check, full Luau typecheck, and Selene lint. The standalone typecheck is Roblox-aware; it generates a Rojo sourcemap and analyzes against the vendored Roblox definitions.

Studio-backed runs are sequential by design. Do not start multiple bridge-backed `make` commands against the same Studio session at once.

## Endurance Traces

Use the maintained one-command trace workflow to compare models or inspect the prompt/response stream:

```sh
make endurance-trace MODEL=google/gemma-3-4b-it DURATION=90 OUT=traces/endurance-gemma.json
make inspect-llm-trace TRACE=traces/endurance-gemma.json
```

That workflow starts Play through the bridge, enables the LLM backend, selects the model, starts endurance mode, waits for the requested duration, exports the server-side trace, and stops Play.

To export the latest trace from an already running Play session:

```sh
make export-llm-trace > traces/manual-session.json
```

Trace captures are local artifacts; keep them under `traces/`, which is gitignored.

## Obstacle Tuning

The in-experience command bar includes a narrow tuning surface for isolated obstacle work:

```text
/tune rampjump
/tune crestdip
/tune chicane
/tune run <n>
/tune compare <n>
/tune set <lever> <value>
/tune pad <ingress|egress> <PadValue>
/tune promote
/tune stop
```

Tune mode owns the session while active. It is for controlled single-sector experiments and comparison telemetry; full-lap verification remains the authority for committed endurance behavior.

## Slash Commands

The public HUD command surface is intentionally small:

```text
/demo endurance
/demo camera
/demo rampitup
/demo repair
/demo llmerror
/demo ui-hotfix
/test <suite>
/tune ...
```

Use `/demo endurance` for manual Studio observation. Use the Makefile for repeatable validation and trace capture.

## Key Documents

- [AGENTS.md](AGENTS.md): coding-agent rules, invariants, and workflow contracts.
- [prd_plan.md](prd_plan.md): original product requirements, schemas, and architecture.
- [plans/agent-handoff.md](plans/agent-handoff.md): current implementation state and durable lessons.
- [docs/code-hygiene.md](docs/code-hygiene.md): static tooling scope and typecheck notes.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
