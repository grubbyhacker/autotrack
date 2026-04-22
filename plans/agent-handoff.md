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

## Current state

- Phase 17 trace ownership is stable:
  - `src/agent/LLMTraceJournal.luau` owns in-memory runs
  - `src/agent/LLMAdapter.luau` is the only canonical emission point
  - export paths are `/test llm_trace_export`, `make export-llm-trace`, and `make endurance-trace ...`
- Phase 18 hardening is the current verifier baseline:
  - sector-entry snap now happens at every sector boundary except corner-to-corner handoffs
  - the old `60` stud corner-owned shoulder is down to `10`
  - Chicane geometry is a smooth wave: `amplitude` is wave height, `transition_length` is peak-to-peak spacing
  - chicane scoring now rewards taller waves and tighter spacing
- Phase 19 is now the current endurance-agent baseline:
  - endurance orchestration returns a full structured `DesignIntent`, not only `sector/mechanic/params_hint`
  - endurance jobs submit from that structured intent directly; the English request text is now a derived HUD/log artifact only
  - proposal and repair prompts both receive the same shared `DesignIntent`
  - trace prompt payloads now expose `design_intent` for `orchestrate`, `propose`, and `repair`
  - free-text orchestrator fields must be truncated/defaulted, not hard-rejected; Gemma 3 4B can emit verbose `rationale` / `desired_feel` text at endurance start
- HUD semantics that matter now:
  - repair attempts only show in the top-edge repair banner when `attempt_current > 0`
  - endurance and hotfix are separate left badges
  - LLM warnings live in the amber strip above the `LLM` panel
  - repair explanation/action callouts are transient and de-duplicated
- Demo/HUD commands in active use: `/demo camera`, `/demo rampitup`, `/demo repair`, `/demo llmerror`, `/demo ui-hotfix`
- Chicane visual cleanup baseline: collision remains gameplay-facing while the visible surface stays visual-only; accepted manual capture is `/mnt/c/Users/roger/screenshots/roblox-studio-20260421-214743.png`; dedicated capture suite remains `phase4_chicane_capture`

## Current reliability posture

- Demo reliability still wins over pure continuity.
- Non-corner straights intentionally use stronger yaw/roll damping and forward-heading pinning than corners.
- Endurance build passes still skip Stage B challenge-up during maximize/endurance loops.
- Corner-exit acceleration remains heading-gated; if the car slides before rotating again, inspect that gate before retuning raw accel.
- RampJump full-lap stability still depends on both geometry and verifier behavior; check `/demo rampitup` after ramp changes.

## Hard-won invariants

- For chicane work, keep collision/verifier path and visual surface separate. Visual cleanup should not retune gameplay unless explicitly intended.
- Parameter-only overlap/sample-spacing tweaks were not enough to fix chicane wedges. The durable fix was changing visible-surface construction.
- Do not reintroduce a visible seam-cover ribbon or stacked underlay under the chicane top surface; that produced obvious spoke/rib artifacts.
- Trimming corner visual shoulders to zero creates V-shaped corners.
- The local Studio bridge is sequential. Do not start multiple `make test ...` runs at once.
- Endurance orchestrator validation should stay strict on enums/shape but tolerant on prose length. Rejecting long `rationale` text can freeze live endurance before the first build.
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
- `make test TEST=phase13_unit`
- `make test TEST=llm_trace_export`
- `make export-llm-trace`
- `make endurance-trace MODEL=google/gemma-3-4b-it DURATION=60 OUT=traces/sample.json`
- `make inspect-llm-trace TRACE=traces/sample.json`

## Recommended next focus

- Keep `phase18` in the gate set whenever sector handoff, damping, or integrity thresholds change.
- Keep `phase14_5` and `phase14_integration` in the gate set for endurance-policy or HUD-decision work.
- Keep `phase19` in the gate set whenever orchestrator prompt contracts, endurance submission flow, or proposal/repair prompt content changes.
- For future track-visual work, treat `phase4_chicane_capture` as the manual screenshot harness and do not mix it with gameplay retunes.
- If CrestDip reliability regresses, inspect lead-in speed and waypoint density before expanding repair logic.
