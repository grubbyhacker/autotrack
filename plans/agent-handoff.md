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
| 11 | Complete — ChallengeScore telemetry, Stage B challenge-up, `/demo maximize`, pad tier expansion |
| 12 | Complete — visual readability pass: track foundation, corner roads, verifier shell, supported ramp visuals |
| 13 | Complete — real LLM via OpenRouter, `LLMConfig`, multi-turn repair history, HUD model selector |
| 14 | Complete — endurance mode orchestration, continuous loop, hotfix terminal HUD |
| 14.5 | Complete — orchestrator memory, endurance objective, HUD decision telemetry, `phase14_5` gate |
| 14 Retune | Complete — straight-entry recovery plus denser flat guidance restored CrestDip/endurance reliability |
| 15 | Complete — RampJump continuous entry arc, shared ramp profile, `phase15` gate |
| 16 | Complete — RampJump playability retune, `/demo rampitup`, full-lap ramp stabilization, `phase16` gate |
| 17 | Complete — server-side LLM trace journal, export path, CLI bridge export command |
| 18 | Complete — deterministic sector-entry snap isolation, comfort-margin integrity gates, `phase18` gate |
| 19 | Complete — structured `DesignIntent` handoff for endurance orchestrate → propose → repair, direct structured endurance submit path, prompt-content fidelity tests |
| 20 | Complete — session-local endurance memory, role notebooks, orchestrator-curated shared lessons, compact HUD memory panel, `phase20` gate |
| 21 | Complete — isolated tune mode plus agent-operable experimental lab, tune-only widened bounds, live base-speed override, structured pass telemetry, `phase21` / `phase21_experiment` gates |

## Current state

- Phase 20 remains the endurance-agent baseline:
  - structured `DesignIntent` handoff is still authoritative
  - bounded orchestrator/proposal/repair memory slices are live
  - malformed structured agent output stays operator-visible in the HUD warning strip
- Phase 21 is now complete and verified:
  - `TuneMode` owns `/tune ...` isolated sector passes on sector `3`
  - tune mode now uses tune-only experimental bounds instead of production lever bounds
  - `car_target_speed` is a tune-owned runtime override wired through `VerifierController`
  - tune attrs now also cover integrity/clearance thresholds: off-track distance, front-body containment, and RampJump/Chicane/CrestDip comfort margins
  - tune telemetry now publishes machine-readable pass records, staged candidate version, last/best batch aggregates, best-so-far state, recent history, bounds summary, and promotion snapshot
  - `TuneExperiment` adds a scriptable isolated comparison harness reachable through `make test TEST=phase21_experiment`
  - live `/tune` now starts in staged mode by default:
    - `/tune run <n>` runs exactly `n` isolated attempts for the current candidate
    - `/tune auto on` restores the continuous spectator loop
    - `/tune auto off` returns to staged mode and may queue behind the current in-flight auto pass
    - tune mutation commands reject while a run is in flight so candidate attribution stays clean
  - hotfix repair continues to use isolated attempts before the later full-lap baseline re-record
  - live Studio validation now also exercised the real `/tune rampjump` surface end-to-end via `AutoTrack_SubmitRequest`, not only the bridge suites:
    - changed all four RampJump levers live (`ramp_angle`, `ramp_length`, `gap_length`, `landing_length`)
    - changed a live pad (`ingress=Boost25`)
    - changed live attrs (`car_target_speed`, `front_body_containment_distance`)
    - confirmed each change appeared in replicated tune summaries and the structured `tune_history_1` pass record
    - confirmed `/tune stop` returned the session to idle and cleared tune state
  - live Studio validation now also exercised the staged batch tune flow for all three mechanics:
    - `RampJump`: staged lever/pad/attr edits, then `/tune run 2`, then `/tune stop`
    - `CrestDip`: staged lever/pad/attr edits, then `/tune run 2`, then `/tune stop`
    - `Chicane`: staged lever/pad/attr edits, then `/tune run 2`, then `/tune stop`
    - all three mechanics started in staged mode with `tune_auto_run=false`, `tune_pass_count=0`, and `tune_candidate_version=1`
    - all staged edits incremented candidate version and appeared in replicated summaries
    - all three mechanics published structured `tune_last_batch_json` and `tune_last_pass_json` after the controlled 2-pass batch
    - all three mechanics cleaned up back to `phase=Idle` after `/tune stop`
    - smoke-result note: `RampJump` produced a mixed 2-pass batch, while the chosen `CrestDip` and `Chicane` smoke candidates both ran successfully as batches but failed integrity on both attempts; this is acceptable because the smoke goal was control-surface validation, not finding a good candidate yet
- Demo/HUD commands in active use: `/demo camera`, `/demo rampitup`, `/demo repair`, `/demo llmerror`, `/demo ui-hotfix`
- Chicane visual cleanup baseline remains: collision is gameplay-facing, visible surface is visual-only, and the accepted capture harness is still `phase4_chicane_capture`

## Current reliability posture

- Demo reliability still wins over pure continuity.
- Non-corner straights intentionally use stronger yaw/roll damping and forward-heading pinning than corners.
- Endurance build passes still skip Stage B challenge-up during maximize/endurance loops.
- Corner-exit acceleration remains heading-gated; inspect that before retuning raw accel.
- RampJump full-lap stability still depends on both geometry and verifier behavior; check `/demo rampitup` after ramp changes.

## Hard-won invariants

- For chicane work, keep collision/verifier path and visual surface separate. Visual cleanup should not retune gameplay unless explicitly intended.
- Parameter-only overlap/sample-spacing tweaks were not enough to fix chicane wedges. The durable fix was changing visible-surface construction.
- Do not reintroduce a visible seam-cover ribbon or stacked underlay under the chicane top surface; that produced obvious spoke/rib artifacts.
- Trimming corner visual shoulders to zero creates V-shaped corners.
- The local Studio bridge is sequential. Do not start multiple `make test ...` runs at once.
- The local Studio bridge has a boot-readiness gate before suite dispatch. If it reports missing `runtime_context`, `ui_state`, `submit_event`, `track`, or `verifier_car`, treat that as a startup regression first.
- `make boot_smoke` is the maintained fast path for startup sanity checks before deeper suite debugging.
- Mid-session Rojo reconnects remain untrustworthy for client validation. For tune/HUD/camera work, use the strict loop: stop Play, restart Play, then retest.
- Tune-lab observability is for the coding agent first. If a useful signal only exists in the camera/HUD visually and not in structured state or trace lines, the lab surface is incomplete.
- Keep tune-only experimental bounds separate from production bounds. Proposal/repair/endurance should stay conservative until a later explicit promotion changes code defaults.
- `AutoTrack_CarTargetSpeed` is now a tune-owned runtime override. Any verifier speed-path change must preserve default behavior when that attr is unset.
- Tune mode is no longer a free-running loop by default. Start a candidate, then use `/tune run <n>` for controlled multi-attempt evaluation. Only `/tune auto on` should re-enable continuous looping.
- `auto off` must be allowed during an in-flight auto pass. It should stop new batches from starting, then settle back to staged mode once the current pass finishes.
- The scriptable experiment harness must restore touched workspace attrs back to their prior values, including `nil`. Dropping untouched-nil restoration leaves stale speed overrides live.
- Live `/tune` validation should inspect the structured replicated pass record, not just `tune_param_summary`. Summary attrs update immediately, but the authoritative proof that the next isolated pass used a change is the latest `tune_history_1` / `tune_last_pass_json` payload.
- For staged tune validation, also inspect `tune_last_batch_json`. It is the authoritative proof that a controlled `/tune run <n>` batch completed for the intended candidate version.
- The current live RampJump smoke outcome worth remembering:
  - mild geometry changes (`ramp_angle=6`, `ramp_length=30`, `gap_length=4`) all produced successful isolated passes
  - `landing_length=40` produced `local_execution_failure` with `invalid_attitude`
  - `ingress=Boost25` and `car_target_speed=120` both pushed the current RampJump toward integrity failure via lost safe reacquire / rough exit
  - adding `front_body_containment_distance=18` still yielded a successful isolated pass in that session
- Endurance orchestrator validation should stay strict on enums/shape but tolerant on prose length. Rejecting long `rationale` text can freeze live endurance before the first build.
- Do not allow `begin_loop` on a flat fresh endurance run. Models can incorrectly declare `TRACK READY` before any obstacle exists; server-side orchestration must guard this.
- Endurance memory notes are advisory, not authoritative. Invalid note formatting should be normalized or dropped instead of aborting endurance mode.
- Invalid structured agent output should be operator-visible. Keep the amber warning strip wired for bad orchestrator / proposal / repair payloads so live failures are diagnosable without opening traces first.
- Shared run memory is orchestrator-curated only. Proposal and repair may emit notes, but they should remain in `proposal` / `repair` scope and never write directly to `shared`.
- If captures do not match the local diff, assume Studio was not really restarted or the wrong session is active.
- The reliable manual capture loop is:
  - set the active Studio instance first
  - stop Play, start Play, fire `phase4_chicane_capture`
  - capture with `C:\\Users\\roger\\capture-roblox.ps1`

## Maintained verification snapshot

- `make test TEST=phase4_chicane`
- `make test TEST=phase4_chicane_capture`
- `make test TEST=phase14_5` and `make test TEST=phase14_integration`
- `make test TEST=phase15`
- `make test TEST=phase16`
- `make test TEST=phase18`
- `make test TEST=phase19`
- `make test TEST=phase20`
- `make test TEST=phase21`
- `make test TEST=phase21_experiment`
- manual live `/tune rampjump` smoke:
  - changed every RampJump lever once
  - changed one pad and two attrs
  - verified structured pass records updated
  - verified `/tune stop` cleanup
- staged tune-mode command surface:
  - `/tune run <n>` verified by `phase21`
  - `/tune auto on|off` verified by `phase21`
- manual live staged `/tune` smoke for all mechanics:
  - `RampJump`, `CrestDip`, and `Chicane` each validated with staged edits + `/tune run 2`
  - verified `tune_last_batch_json` / `tune_last_pass_json` publication for each
  - verified `/tune stop` cleanup for each
- `make boot_smoke`
- `make test TEST=phase13_unit`
- `make test TEST=llm_trace_export`
- `make export-llm-trace`
- `make endurance-trace MODEL=google/gemma-3-4b-it DURATION=60 OUT=traces/sample.json`
- `make endurance-trace MODEL=qwen/qwen-turbo DURATION=60 OUT=traces/sample-qwen.json`
- `make inspect-llm-trace TRACE=traces/sample.json`

## Recommended next focus

- Use `phase21_experiment` plus the live `/tune` surface to search for better mechanic defaults and base-speed candidates without expanding production bounds yet.
- When a better baseline is proven, promote it explicitly into `Constants` / `LevelMappings` / tuned mechanic defaults by normal repo edits, then re-run `phase21`, `phase21_experiment`, and `phase18`.
- Keep `phase14_5` and `phase14_integration` in the gate set for endurance-policy or HUD-decision work.
- Keep `phase19` in the gate set whenever orchestrator prompt contracts or endurance submission flow changes.
- Keep `phase20` in the gate set whenever endurance memory schemas or HUD memory surfaces change.
- For future track-visual work, treat `phase4_chicane_capture` as the manual screenshot harness and do not mix it with gameplay retunes.
