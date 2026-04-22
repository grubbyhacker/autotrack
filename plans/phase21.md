# Phase 21 — Agent-Operable Experimental Tune Lab

## Summary

Phase 21 extends isolated tune mode into an agent-operable experimental lab.

The primary goal is not a player-facing tuning UX. It is to let the coding
agent:

- change mechanic and verifier parameters live in isolated sector passes
- observe pass outcomes through machine-readable telemetry instead of camera
  intuition
- compare candidate configurations quickly without paying the full-lap restart
  cost for every trial
- derive stronger defaults through experimentation, then explicitly save the
  chosen defaults back into code

Full-lap verification remains the authoritative production validation path.
Normal proposal, repair, endurance, and commit flows stay on the existing
conservative production bounds.

Chosen defaults:

- the lab remains tune-only
- optimization target is balanced, not spectacle-only
- base verifier speed is exposed as a tune-owned runtime attr
- promotion into code is explicit and separate from the live tune session
- experiment output must be reachable through structured state, traces, and the
  maintained `make` path

## Public Interface / Type Changes

- Keep the existing `/tune ...` command family:
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
- Add tune-only support for `car_target_speed` in the verifier attr whitelist.
- Add tune-only support for safety-envelope and comfort-threshold attrs used by:
  - `FailureDetector`
  - `RampJumpIntegrity`
  - `ChicaneIntegrity`
  - `CrestDipIntegrity`
- Extend `UIState` tune telemetry with machine-readable pass summaries,
  recent-history slots, best-so-far summary, and promotion snapshot fields.
- Add one maintained experiment suite entry through the existing Studio bridge
  path for agent-driven isolated comparisons.

## Implementation Changes

- Keep `LevelMappings.LEVER_BOUNDS` as the production envelope.
- Add a tune-only experimental bounds source used only by `TuneMode.setLever`.
- Keep experimental bounds finite and builder-safe:
  - authored geometry must still fit `Constants.STRAIGHT_LENGTH`
  - width-sensitive mechanics must still respect the current `TRACK_WIDTH`
    reality
  - sector completeness / continuous path guarantees must still hold
- Extend `TuneMode` to own:
  - experimental per-mechanic bounds reporting
  - live `car_target_speed` override
  - staged candidate control with explicit batch execution
  - optional spectator-friendly auto-run mode
  - candidate-version and batch tagging for pass attribution
  - pass-history capture
  - last/best batch aggregate capture
  - best-so-far tracking
  - promotion snapshot output
- Extend `VerifierController` so tune-owned `car_target_speed` overrides affect:
  - isolated sector entry snap speed
  - straight and corner target speed calculations
  - pad-adjusted persistent target speed
  - emitted current/target/commanded speed surfaces
- Extend integrity / failure thresholds so tune-owned runtime attrs can relax or
  tighten:
  - off-track and front-body containment distances
  - RampJump vertical / reacquire / safe-exit comfort thresholds
  - Chicane excursion / containment thresholds
  - CrestDip airtime / apex-speed / safe-exit comfort thresholds
- Upgrade tune observability to publish structured agent-readable pass records:
  - applied params
  - applied pads
  - applied tune attrs
  - success/failure
  - failure type/detail
  - entry/exit speed
  - lap time
  - slowdown ratio
  - target-sector comfort / reacquire / containment metrics when present
- Add a bounded experiment harness that:
  - configures a candidate state programmatically
  - runs repeated isolated passes
  - emits parseable aggregated summaries for comparison
- Change live `/tune` semantics so the coding agent can evaluate one candidate at
  a time without mixed in-flight state:
  - `/tune <mechanic>` starts in staged mode with no automatic pass loop
  - `/tune run <n>` runs exactly `n` isolated attempts against the current
    staged candidate
  - `/tune auto on|off` toggles the old continuous spectator loop
  - tune mutation commands are rejected while a batch is in flight so the car is
    not retuned mid-run
  - batch telemetry must report aggregate stability across attempts, not only
    the latest single pass
- Keep all tune changes session-local and routed through `SectorApplier`.
- Do not add runtime commands that write tracked repo files.

## Test Plan

- Extend `src/orchestrator/TestPhase21.luau`
- Keep `phase21` wired through:
  - `src/orchestrator/TestDispatcher.luau`
  - `tools/test_bridge_config.json`
  - `Makefile`
- Add a dedicated experiment harness suite wired into the same maintained path.
- Add assertions for:
  - tune mode accepts values beyond production bounds but clamps to tune
    experimental bounds
  - production proposal / normalization paths still use production bounds
  - `/tune attr car_target_speed <value>` changes isolated entry snap and live
    target-speed behavior
  - integrity / containment attrs change evaluator and failure-detector behavior
    at runtime
  - tune mode starts in staged candidate mode by default
  - `/tune run <n>` emits parseable aggregate batch output and increments pass
    history deterministically
  - `/tune auto on|off` toggles continuous evaluation without breaking staged
    candidate semantics
  - tune mutation commands are blocked while a batch is in flight
  - tune telemetry publishes pass metrics, best-so-far state, recent history,
    batch aggregates, and promotion snapshot
  - `reset`, `revert`, and `stop` clear tune-owned overrides
  - experiment output is parseable and stable across repeated passes

## Verification

- `make test TEST=phase21`
- `make test TEST=phase21_experiment`
- keep these suites in the gate set when touching tune / verifier behavior:
  - `make test TEST=phase18`
  - `make test TEST=phase14_integration`
  - relevant mechanic suites as needed:
    - `phase4_rampjump`
    - `phase4_crestdip`
    - `phase4_chicane`

## Assumptions

- The lab is primarily for the coding agent, not for human-in-the-loop
  screenshot interpretation.
- Observability must be available through machine-readable state, not only HUD
  text.
- Production repair / proposal / endurance behavior stays conservative in this
  phase.
- The experiment harness is bounded and scriptable, not a general autonomous
  optimizer.
- Promotion of new defaults still happens by normal local-file edits after a
  tune session proves a better baseline.
- Live tune mode should optimize for candidate-level control first and
  spectator-friendly continuous looping second.
