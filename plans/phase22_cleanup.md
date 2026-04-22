# Phase 22 — Command Surface Cleanup and Boundary Pass

This is the authoritative Phase 22 plan file for this milestone.

## Context

The repo now has stronger maintained coverage through the local `make ...`
workflow, and Phase 21 established tune mode as an isolated experimental lab.
The next planned milestone is deeper, more formal mechanic-specific tuning.
Before that work, the orchestrator layer needs cleanup: legacy slash/demo
surfaces still exist, `JobRunner` carries too many responsibilities, and
several mode boundaries are blurred.

This phase is a conservative cleanup milestone. It prefers removals and
boundary fixes over behavior redesign.

## Goals

- Remove clearly obsolete legacy command surfaces that are no longer part of
  the documented product.
- Split slash-command routing from the core CI job execution path.
- Keep the supported command surface narrow and intentional.
- Preserve documented demos, tune mode, endurance behavior, hotfix behavior,
  and the maintained Studio bridge / `make` workflow.
- Improve seams around mechanic-local tuning, repeated isolated runs, telemetry
  publication, and future command expansion.

## Non-Goals

- No redesign of tune mode behavior or telemetry semantics.
- No redesign of endurance policy, hotfix policy, or verifier physics.
- No change to the maintained local bridge protocol beyond what is required to
  preserve it through routing cleanup.
- No broad UI redesign.
- No speculative deletion of low-confidence legacy boot flags or remotes
  without proof that they are unused.

## Repo-Informed Assessment

### Remove-now candidates

- Undocumented legacy `/demo crest`
- Undocumented legacy `/demo maximize`
- Undocumented legacy `/demo extreme`
- Undocumented legacy `/demo hotfix`
- Undocumented `/llm on|off|model`
- `src/orchestrator/MaximizerAgent.luau`, if maximize is fully removed
- `JobRunner` state and helpers tied only to the removed demo paths:
  - `_extremeDemoActive`
  - `_extremePriorStates`
  - `HOTFIX_DEMO_REQUEST`
  - `buildHotfixDemoState`

### Refactor-now candidates

- `src/orchestrator/JobRunner.luau`
  - currently owns slash-command parsing, mode gating, HUD demo previews,
    endurance entry, `/test` dispatch, and the real propose → verify → repair
    loop
- `src/orchestrator/Main.server.luau`
  - boot, baseline flow, remote wiring, and startup mode wiring are mixed in
    one module
- `src/orchestrator/UIState.luau`
  - generic runtime state publication and HUD-preview/demo mutation are tightly
    coupled
- `src/orchestrator/OrchestratorAgent.luau`
  - endurance policy, baseline fallback, telemetry shaping, and loop startup
    are bundled together

### Leave-alone candidates

- `src/orchestrator/TuneMode.luau`
  - keep as the foundation for later mechanic-specific tuning; reshape routing
    around it rather than folding it back into `JobRunner`
- `src/orchestrator/HotfixAgent.luau`
  - preserve real hotfix flow; only decouple it from demo-only trigger paths
- `studio/AutoTrackTestBridge.server.lua`
- `tools/autotrack_test_cli.py`
- `tools/test_bridge_config.json`
  - only touch these to preserve and extend the maintained `make` flow

## Workstreams

### 1. Command-surface contract first

- Add dedicated cleanup suites before deletions/refactors:
  - `phase22_command_surface`
  - `phase22_endurance_entry`
- Assert the supported slash-command surface explicitly.
- Assert that removed legacy commands are rejected with stable errors.
- Assert session gating between demo, tune, endurance, and `/test`.

### 2. Safe legacy removals

- Remove `/demo crest`, `/demo maximize`, `/demo extreme`, and `/demo hotfix`.
- Remove `/llm on|off|model`.
- Delete `MaximizerAgent` if no maintained workflow depends on it.
- Trim tests/docs that only exist for those removed paths.

### 3. Boundary cleanup

- Extract slash-command parsing and mode dispatch out of `JobRunner`.
- Keep `JobRunner` focused on executing a validated request through propose →
  verify → repair → commit/revert.
- Move HUD preview-demo handling into a dedicated helper/module.
- Keep documented demo presets and `/test` behavior available through the new
  router layer.

### 4. Endurance and hotfix seam cleanup

- Preserve endurance and hotfix behavior, but stop treating endurance as an
  incidental `/demo` branch internally.
- Introduce a dedicated internal endurance entry seam.
- Keep temporary compatibility if the maintained bridge still needs an old
  command string during the refactor.

### 5. Tune-mode unblocking cleanup

- Preserve tune mode’s isolated ownership and command surface exactly.
- Ensure future mechanic-specific tune commands can be added in the command
  router without further bloating `JobRunner`.
- Keep tune-specific validation, telemetry, and mode-gating paths isolated from
  general demo/endurance logic.

### 6. Docs and maintained test surface sync

- Update `AGENTS.md`, `TestDispatcher`, `tools/test_bridge_config.json`,
  `Makefile`, and handoff docs together.
- Ensure the documented slash-command surface exactly matches the implemented
  one.

## Test Plan

### Baseline before edits

- `make test-contracts`
- `make boot_smoke`
- `make refactor_fast`
- `make mechanics_regression`
- `make test TEST=phase14_integration`
- `make test TEST=phase14_5`
- `make test TEST=phase20`
- `make test TEST=phase21`
- `make test TEST=phase21_experiment`
- `make test TEST=llm_trace_export`

### Add first

- `make test TEST=phase22_command_surface`
  - `skip_baseline`
  - covers supported slash commands, removed legacy commands, busy-state
    rejection, tune/demo/test gating, and HUD preview toggles
- `make test TEST=phase22_endurance_entry`
  - `skip_baseline`
  - covers endurance entry through the maintained bridge-facing path and any
    compatibility alias retained during refactor

### During cleanup

- After safe deletions:
  - `make test-contracts`
  - `make test TEST=phase22_command_surface`
  - `make test TEST=phase11_unit`
- After router extraction:
  - `make refactor_fast`
  - `make test TEST=phase22_command_surface`
  - `make test TEST=phase22_endurance_entry`
  - `make test TEST=phase20`
  - `make test TEST=phase21_unit`
- After endurance/bridge seam changes:
  - `make test TEST=phase14_5`
  - `make test TEST=phase14_integration`
  - `make test TEST=llm_trace_export`

### Final validation

- `make test-contracts`
- `make boot_smoke`
- `make refactor_fast`
- `make mechanics_regression`
- `make test TEST=phase14_5`
- `make test TEST=phase14_integration`
- `make test TEST=phase20`
- `make test TEST=phase21`
- `make test TEST=phase21_experiment`
- `make test TEST=llm_trace_export`
- If endurance entry wiring changed:
  - `make endurance-trace MODEL=qwen/qwen-turbo DURATION=60 OUT=traces/phase22-endurance.json`

## File Plan

### Primary change targets

- `src/orchestrator/JobRunner.luau`
- `src/orchestrator/CameraDemo.luau`
- `src/orchestrator/OrchestratorAgent.luau`
- `src/orchestrator/UIState.luau`
- `src/orchestrator/Main.server.luau`

### Likely deletion targets

- `src/orchestrator/MaximizerAgent.luau`

### Test and maintained workflow updates

- `src/orchestrator/TestPhase11.luau`
- `src/orchestrator/TestPhase14.luau`
- `src/orchestrator/TestPhase20.luau`
- `src/orchestrator/TestPhase21.luau`
- `src/orchestrator/TestDispatcher.luau`
- `tools/test_bridge_config.json`
- `Makefile`
- `src/orchestrator/StudioTestBootstrap.server.luau`

### Documentation updates

- `AGENTS.md`
- `plans/agent-handoff.md`

## Exit Criteria

- The supported slash-command surface is documented, intentionally small, and
  matched by tests.
- Selected legacy undocumented demo/command paths are deleted from code, tests,
  and docs.
- `JobRunner` no longer owns both command routing and the full core CI
  execution path.
- Tune mode remains isolated and fully functional through the maintained
  workflow.
- Endurance mode, hotfix mode, HUD preview demos, `/test`, and maintained
  bridge flows still work through `make`.
- `plans/agent-handoff.md` is updated with the cleanup outcome and any new
  durable invariants.

## Recommended Commit Sequence

1. Add protection first
   - Add `phase22_command_surface` and `phase22_endurance_entry`.
   - Wire them through `TestDispatcher`, `tools/test_bridge_config.json`, and
     `Makefile`.
2. Remove clearly dead legacy surfaces
   - Delete `/demo crest`, `/demo extreme`, `/demo hotfix`, and `/llm`.
   - Trim tests/docs for those paths.
3. Remove maximize path
   - Delete `MaximizerAgent`.
   - Remove maximize-only `JobRunner` branch.
   - Replace or trim `TestPhase11` maximize assertions while preserving
     challenge-up coverage.
4. Extract command routing from `JobRunner`
   - Introduce a dedicated slash-command router / mode-dispatch helper.
   - Move HUD preview demo handling out of core job execution.
5. Reshape endurance entry seam
   - Make endurance a dedicated mode entry internally.
   - Preserve maintained bridge compatibility.
6. Finish boundary cleanup and docs
   - Tighten `JobRunner` API.
   - Sync `AGENTS.md` and `plans/agent-handoff.md`.

## Assumptions

- The documented commands in `AGENTS.md` are the intended supported surface
  unless a maintained workflow proves otherwise.
- Endurance behavior must remain, but it does not need to remain conceptually
  grouped with demo-only commands.
- Tune mode is the correct foundation for later mechanic-specific tuning and
  should be reshaped around, not deleted.
- Low-confidence legacy flags such as `AutoTrack_CameraLoopDemo` are out of
  scope unless implementation-time evidence proves they are dead.
