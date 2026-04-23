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
| 26 | Complete — Session HUD simplification (Base/Last/% + Track/Budget), committed-lap display attrs, and Overview-only per-sector committed score annotations |
| 27 | Complete — RampJump return: mode-aware tuning/repair policy, profile-mode pathing, upright hard-landing telemetry + integrity, and repaired-score retention gate |
| 28 | Complete — scoped Luau hygiene baseline (`fmt`/`fmt-check`/`typecheck`/`lint`/`hygiene`), pinned tools/config, and docs contract |
| 29 | Complete — hygiene ratchet to full `src/common` format/lint coverage with conservative `Types.luau` typecheck exclusion |
| 30 | Complete — repo-wide Luau format/lint coverage, `typecheck-report`, and Phase 30 suite wiring with policy-aligned Phase 21 experiment assertions |
| 31 | Planned — Roblox-aware Luau typecheck foundation (`plans/phase31.md`) |

## Current state

- Public slash-command surface remains intentionally narrow: `/demo endurance|camera|rampitup|repair|llmerror|ui-hotfix`, `/test <suite>`, `/tune ...`.
- Tune mode remains the Phase 21 lab: staged-by-default, controlled run batches, baseline/candidate compare, auto-loop toggle, explicit promote snapshot, and production-baseline `reset`.
- Phase 24 endurance verification profile is now two-stage for endurance-origin jobs: isolated sector vetting first, then one commit-lap gate before commit.
- Phase 25 scoring/objective policy now treats pad usage as telemetry-only (no explicit score penalty) and ranks endurance candidates using realized committed outcomes plus a light mechanic exploration bonus.
- Phase 26 Session HUD now reads commit-authoritative lap attrs (`committed_lap_time`/`committed_slowdown_ratio`) for `Last/%`, while per-sector committed scores move to Overview-only label annotations (`sector_<id>_committed_score`).
- Phase 27 now shifts RampJump back toward high-risk/high-reward with repaired-score retention gating, profile-mode pathing (`linear_blend`/`curved_lift`), and upright-aware hard-landing integrity acceptance backed by touchdown telemetry.
- Phase 30 expands `make fmt`, `make fmt-check`, and `make lint` repo-wide across tracked `.luau` source under `src/` and `studio/`, keeps `make typecheck` on a documented green subset, and adds `make typecheck-report` as the non-gating full-repo analyzer backlog report.
- Phase 31 is now planned in `plans/phase31.md`. The main typecheck blockers are analyzer-environment issues, not hygiene noise: current `luau-lsp analyze` only knows the hand-declared globals in `tools/luau/globals.d.luau`, so Roblox engine globals/types (`Vector3`, `CFrame`, `Enum`, `DateTime`, `Camera`, `BasePart`, etc.) and Rojo/DataModel require resolution are still missing from the full-repo analyzer path.

## Hard-won invariants

- Phase execution is strict: `plans/phaseN.md` is canonical unless the human explicitly names a different plan file; `agent-handoff.md` is context only, and competing plan files require clarification instead of a synthesized replacement.
- The local Studio bridge is sequential. Do not start multiple `make test ...` runs at once.
- The bridge CLI now has a queue lock (`tools/.autotrack_bridge.lock`) so accidental concurrent bridge commands serialize; keep runs intentionally sequential for fastest feedback.
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
- Session `Last/%` is commit-authoritative. Do not bind those fields to `last_lap_time`/`slowdown_ratio`; those remain generic latest-run telemetry and can represent isolated-stage checks.
- RampJump airborne guidance must not keep re-injecting positive Y velocity each frame. Preserve ballistic vertical motion and only cap extreme upward spikes.
- RampJump target-sector stability vertical/angular caps must apply in any RampJump sector context, not only when that sector is the explicit target.
- Launch-outlier classification should require prolonged hang-time gating; high airtime-distance alone can false-positive at high forward speeds.
- Repaired RampJump commits are now score-gated: success is not commit-authoritative if repaired score drops below the configured retention threshold and score-band floor.
- `AutoTrack_RampJumpProfileMode` supports both string mode values (`linear_blend`/`curved_lift`) and numeric tune-lab toggles (`0`/`1`).
- RampJump `no_progress` repair policy is boost-first then shorten/soften climb; do not lengthen ramp length for uphill speed-bleed failures.
- For RampJump on real LLM full-state repair path, sanitize the returned state before validation: cap per-attempt lever deltas, cap cumulative drift from the first proposal, and prevent brake escalation when failure evidence says the issue is speed-bleed rather than instability.
- `phase14_partial_repair_state_merged` should assert partial-state merge + bounded guardrail normalization (preserved unspecified levers and bounded landing adjustment), not pre-Phase-27 "flatten jump aggressively" expectations.
- RampJump on-ramp/landing instability should be corrected in the verifier first (grounded surface stabilization) before widening failure tolerances globally; otherwise weaker models overfit around physics noise and churn repair attempts.
- Endurance `challenge_up` for RampJump should be gated by baseline quality, not only score/headroom: skip do-over after repaired commits and skip when the committed ramp is already near top-end geometry with strong ingress boost.
- `phase21_experiment_harness_distinguishes_better_candidate` should assert the comparison contract (winner labels and differing heuristic/challenge aggregates), not a hard-coded winner. Live experiment telemetry can legitimately change which candidate wins.
- Full-repo `typecheck-report` failures currently cluster into three buckets: missing Roblox globals/types, unresolved `Types.*` exported aliases downstream of `src/common/Types.luau`, and only then genuine module-level code/type issues. Fix the analyzer environment and Rojo/sourcemap resolution first or the remaining report is mostly noise.

## Maintained verification snapshot

- `make test-contracts`
- `make boot_smoke`
- `make refactor_fast`
- `make mechanics_regression`
- `make test TEST=phase14_integration`
- `make test TEST=phase21`
- `make test TEST=phase21_unit`
- `make test TEST=phase21_experiment`
- `make test TEST=phase21_rampjump_torture`
- `make test TEST=phase23`
- `make test TEST=phase24`
- `make test TEST=phase27`
- `make fmt-check`
- `make typecheck`
- `make typecheck-report`
- `make lint`
- `make hygiene`
- `make phase30`
- `make test TEST=llm_trace_export`
- `make endurance-trace MODEL=google/gemma-3-4b-it DURATION=60 OUT=traces/endurance-gemma-after-challenge-gate.json`
- `make endurance-trace MODEL=google/gemma-3-4b-it DURATION=120 OUT=traces/endurance-gemma-after-challenge-gate-120.json`
