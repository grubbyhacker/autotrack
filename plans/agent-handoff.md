# Agent Handoff

## Phase completion status

| Phase | Status |
|-------|--------|
| 1 | Complete — track generator, fixed corners, numbered editable straights, job lock, baseline lap |
| 2 | Complete — sector registry, serializer, applier, rollback |
| 3 | Complete — verifier car, semi-rail controller, failure detection, reacquire |
| 4 | Complete — RampJump, Chicane, CrestDip builders + PadBuilder |
| 4.5 | Complete — corner arc paths + speed reduction |
| 5 | Complete — integrity evaluators + FailurePacket wiring |
| 6 | Complete — CI orchestrator state machine (no LLM) |
| 7 | Complete — LLM adapter boundary + swappable mock/stub backend |
| Local CLI | Complete — terminal Studio bridge + `make` targets |
| 8 | Complete — broadcast HUD + replicated UI state + live markers |
| 9 | Complete — CrestDip path + early integrity gating + repair-story tuning |
| 10 | Complete — RampJump/Chicane rigor + persistent pad speed semantics |
| 11 | Complete — ChallengeScore telemetry, Stage B challenge-up, pad tier expansion |
| 12 | Complete — visual readability pass: track foundation, corner roads, verifier shell, supported ramp visuals |
| 13 | Complete — real LLM via OpenRouter, `LLMConfig`, multi-turn repair history, HUD model selector |
| 14 | Complete — endurance mode orchestration, continuous loop, hotfix terminal HUD |
| 14.5 | Complete — orchestrator memory, endurance objective, HUD decision telemetry, `phase14_5` gate |
| 14 Retune | Complete — straight-entry recovery plus denser flat guidance restored CrestDip/endurance reliability |
| 15 | Complete — RampJump continuous entry arc, shared ramp profile, `phase15` gate |
| 16 | Complete — RampJump playability retune, `/demo rampitup`, full-lap ramp stabilization, `phase16` gate |
| 17 | Complete — server-side LLM trace journal, export path, CLI bridge export command |
| 18 | Complete — deterministic sector-entry snap isolation, comfort-margin integrity gates, `phase18` gate |
| 19 | Complete — structured `DesignIntent` handoff for endurance orchestrate → propose → repair |
| 20 | Complete — session-local endurance memory, role notebooks, shared lessons, compact HUD memory panel |
| 21 | Complete — isolated tune mode plus agent-operable experimental lab and structured pass telemetry |
| 22 | Complete — command router extraction, HUD preview extraction, dedicated `startEndurance()` seam, legacy alias cleanup while preserving `/demo endurance` |

## Current state

- Public slash-command surface is intentionally narrow:
  - `/demo endurance`
  - `/demo camera`
  - `/demo rampitup`
  - `/demo repair`
  - `/demo llmerror`
  - `/demo ui-hotfix`
  - `/test <suite>`
  - `/tune ...`
- Legacy aliases `/demo crest`, `/demo maximize`, `/demo extreme`, `/demo hotfix`, and `/llm ...` are intentionally rejected by the router.
- Endurance mode no longer relies on a public slash alias for maintained tooling:
  - `StudioTestBootstrap` now starts it through `JobRunner.startEndurance()`
  - `make endurance-trace` therefore depends on the dedicated internal seam, while `/demo endurance` remains the public trigger
- `JobRunner.submit` no longer owns slash parsing or HUD preview mutation.
- Tune mode remains the Phase 21 experimental lab:
  - staged by default
  - `/tune run <n>` for controlled batches
  - `/tune auto on|off` for continuous looping
  - experimental bounds remain separate from production bounds

## Current reliability posture

- Demo reliability still wins over pure continuity.
- Non-corner straights still intentionally use stronger yaw/roll damping and forward-heading pinning than corners.
- RampJump full-lap stability still depends on both geometry and verifier behavior; keep checking `/demo rampitup` after ramp changes.
- Invalid structured agent output should remain operator-visible in the HUD warning strip.

## Hard-won invariants

- Phase execution is strict: `plans/phaseN.md` is canonical unless the human explicitly names a different plan file; `agent-handoff.md` is context only, and competing plan files require clarification instead of a synthesized replacement.
- The local Studio bridge is sequential. Do not start multiple `make test ...` runs at once.
- The bridge boot-readiness gate is authoritative. Missing `runtime_context`, `ui_state`, `submit_event`, `track`, or `verifier_car` is a startup regression first.
- Aggregate test gate modules must lazy-require child suites. Eager top-level requires can collapse boot via cycles.
- Mid-session Rojo reconnects remain untrustworthy for HUD/camera/tune validation. Stop Play, restart Play, retest.
- Tune observability must stay structured. The authoritative proof of a candidate/pass is the replicated pass payloads (`tune_history_1`, `tune_last_pass_json`, `tune_last_batch_json`), not only summary attrs.
- Tune mode is staged by default. Use `/tune run <n>` for controlled evaluation; only `/tune auto on` should restore continuous looping.
- Keep tune-only experimental bounds separate from production bounds until a later explicit promotion changes code defaults.
- `AutoTrack_CarTargetSpeed` is a tune-owned runtime override. Default verifier behavior must stay unchanged when the attr is unset.
- Endurance entry for maintained tooling now goes through `JobRunner.startEndurance()`, but `/demo endurance` remains a required public command. Keep both paths consistent.
- The old maximize campaign code path has been removed. Do not reintroduce maximize-specific helpers or tests unless the product direction changes explicitly.

## Maintained verification snapshot

- `make test-contracts`
- `make boot_smoke`
- `make refactor_fast`
- `make mechanics_regression`
- `make test TEST=phase14_5`
- `make test TEST=phase14_integration`
- `make test TEST=phase19`
- `make test TEST=phase20`
- `make test TEST=phase21`
- `make test TEST=phase21_unit`
- `make test TEST=phase21_experiment`
- `make test TEST=phase22`
- `make test TEST=phase22_command_surface`
- `make test TEST=phase22_endurance_entry`
- `make test TEST=llm_trace_export`

## Recommended next focus

- Use the Phase 21 tune lab plus `phase21_experiment` to search for better mechanic defaults and base-speed candidates without expanding production bounds yet.
- When a better baseline is proven, promote it explicitly into repo defaults, then rerun `phase21`, `phase21_experiment`, and `phase18`.
- Keep `phase22`, `phase20`, and `phase21_unit` in the gate set for future command-routing, endurance-entry, or tune-surface refactors.
