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
| 23 | Complete — balanced-risk tuning milestone, production-baseline compare/promote tune controls, proposer-owned endurance challenge-up, reliability-as-telemetry objective |
| 24 | Complete — endurance isolated proposal/repair verification (3-pass isolated + commit-lap gate), challenge-up profile alignment, commit-only budget refresh |
| 25 | Complete — pad-neutral challenge scoring, realized-committed-score endurance objective, and prompt-policy shift away from repairable-risk wording |

## Current state

- Public slash-command surface remains intentionally narrow: `/demo endurance|camera|rampitup|repair|llmerror|ui-hotfix`, `/test <suite>`, `/tune ...`.
- Legacy aliases `/demo crest`, `/demo maximize`, `/demo extreme`, `/demo hotfix`, and `/llm ...` are intentionally rejected by the router.
- Maintained endurance tooling starts through `JobRunner.startEndurance()`, while `/demo endurance` remains the public trigger.
- Tune mode remains the Phase 21 lab: staged-by-default, controlled run batches, baseline/candidate compare, auto-loop toggle, explicit promote snapshot, and production-baseline `reset`.
- Phase 24 endurance verification profile is now two-stage for endurance-origin jobs: isolated sector vetting first, then one commit-lap gate before commit.
- Phase 25 scoring/objective policy now treats pad usage as telemetry-only (no explicit score penalty) and ranks endurance candidates using realized committed outcomes plus a light mechanic exploration bonus.
- RampJump launch-outlier observability is now first-class: `RunMetrics.launch_outlier`/`launch_outlier_reasons`, trace hooks (`[TRACE] launch_outlier ...`, `[TRACE] tune_launch_outlier ...`), and tune pass telemetry (`hang_time`, `airtime_distance`, `vertical_displacement`).
- Maintained stress suite: `phase21_rampjump_torture` (90 isolated attempts; parseable summary `phase21_rampjump_torture_summary outliers=... max_hang=... max_air=... max_vertical=...`).

## Hard-won invariants

- Phase execution is strict: `plans/phaseN.md` is canonical unless the human explicitly names a different plan file; `agent-handoff.md` is context only, and competing plan files require clarification instead of a synthesized replacement.
- The local Studio bridge is sequential. Do not start multiple `make test ...` runs at once.
- The bridge boot-readiness gate is authoritative. Missing `runtime_context`, `ui_state`, `submit_event`, `track`, or `verifier_car` is a startup regression first.
- Aggregate test gate modules must lazy-require child suites. Eager top-level requires can collapse boot via cycles.
- Mid-session Rojo reconnects remain untrustworthy for HUD/camera/tune validation. Stop Play, restart Play, retest.
- Tune observability must stay structured. The authoritative proof of a candidate/pass is the replicated pass payloads (`tune_history_1`, `tune_last_pass_json`, `tune_last_batch_json`), not only summary attrs.
- Tune mode is staged by default. Use `/tune run <n>` for controlled evaluation; only `/tune auto on` should restore continuous looping.
- Keep tune-only experimental bounds separate from production bounds unless an explicit milestone promotes the new baseline into repo defaults.
- `AutoTrack_CarTargetSpeed` is a tune-owned runtime override. Default verifier behavior must stay unchanged when the attr is unset.
- `/tune compare` must clear tune-only runtime attrs for the baseline leg; otherwise the "baseline" result is contaminated by the staged candidate's overrides.
- `/tune reset` is a production-baseline restore, not a raw lab-default restore. `/tune revert` is still the committed-state restore.
- Endurance entry for maintained tooling now goes through `JobRunner.startEndurance()`, but `/demo endurance` remains a required public command. Keep both paths consistent.
- The old maximize campaign code path has been removed. Challenge-up now means deterministic Stage B for player/extreme requests or proposer do-over in endurance. In `JobRunner`, forward-declare helper locals used by earlier local functions (`pauseForUI`, `pauseOnFailure`) or the endurance challenge-up path will crash with nil calls. Do not reintroduce maximize-specific helpers or tests unless product direction changes explicitly.
- Endurance build-time budget/slowdown refresh should come from committed full-lap results only. Isolated-stage proposal/repair vetting telemetry is intentionally non-authoritative for budget state.
- ChallengeScore is now pad-neutral by policy. Do not reintroduce mechanic/side-specific pad penalties unless product direction explicitly changes.
- Endurance objective ranking is now realized-outcome-led (commit rate + committed score history), with only a small exploration nudge for underused mechanics.
- RampJump airborne guidance must not keep re-injecting positive Y velocity each frame. Preserve ballistic vertical motion and only cap extreme upward spikes.
- RampJump target-sector stability vertical/angular caps must apply in any RampJump sector context, not only when that sector is the explicit target.
- Launch-outlier classification should require prolonged hang-time gating; high airtime-distance alone can false-positive at high forward speeds.

## Maintained verification snapshot

- `make test-contracts`
- `make boot_smoke`
- `make refactor_fast`
- `make mechanics_regression`
- `make test TEST=phase6_unit`
- `make test TEST=phase9_unit`
- `make test TEST=phase11_unit`
- `make test TEST=phase14_unit`
- `make test TEST=phase14_integration`
- `make test TEST=phase19`
- `make test TEST=phase20`
- `make test TEST=phase21`
- `make test TEST=phase21_unit`
- `make test TEST=phase21_experiment`
- `make test TEST=phase21_rampjump_torture`
- `make test TEST=phase22`
- `make test TEST=phase22_command_surface`
- `make test TEST=phase22_endurance_entry`
- `make test TEST=phase23`
- `make test TEST=phase24`
- `make test TEST=llm_trace_export`

## Recommended next focus

- Use the Phase 23 tune surface one mechanic at a time: `compare`, pause for lessons learned, then `promote` only after the new baseline is clearly better in both tune telemetry and full-lap validation.
- After any RampJump verifier/control change, rerun `phase21_unit`, `phase21_experiment`, and `phase21_rampjump_torture` before full-lap/endurance validation.
- After any further production tuning pass, rerun `phase21`, `phase23`, and `phase14_integration` sequentially through the maintained bridge.
- After changes to endurance proposal/repair verification flow, rerun `phase24`, `phase22_endurance_entry`, and `phase23` sequentially through the maintained bridge.
- Keep `phase22`, `phase20`, and `phase21_unit` in the gate set for future command-routing, endurance-entry, or tune-surface refactors.
