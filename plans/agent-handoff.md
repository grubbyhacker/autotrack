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
| Local CLI | Complete — terminal Studio bridge + make targets |
| 8 | Complete — broadcast HUD + replicated UI state + live markers |
| 9 | Complete — CrestDip path + early integrity gating + repair-story tuning |
| 10 | Complete — RampJump/Chicane rigor + persistent pad speed semantics |
| 11 | Complete — ChallengeScore telemetry, Stage B challenge-up, `/demo maximize` campaign, pad tier expansion |
| 12 | Complete — visual readability pass: sector shells, corner roads, F1 verifier shell, ramp supports |
| 13 | Complete — real LLM via OpenRouter, LLMConfig, multi-turn repair history, HUD model selector |
| 14 | **In progress** — see `plans/phase14.md` |

## Phase 14 status

Chunks A and B are **complete and tested**. Chunks C, D, E are not started.

### Completed (A + B, with post-implementation retuning)

**Chunk A — Physics tightening + extreme parameters:**
- `CAR_TARGET_SPEED` / `BASELINE_SPEED`: 80 → 130 studs/s initially, then retuned to **100 studs/s** after obstacle reliability regressions
- `CORNER_SPEED_FACTOR`: retuned to **0.26** (~26 studs/s at 100, matching the intended corner feel)
- `LinearVelocity.MaxForce`: 10000 → `math.huge` (instantaneous corner deceleration; no look-ahead needed)
- `RAMPJUMP_MIN_AIR_DISTANCE`: 5 → 10 initially, then retuned to **4.5** after proving 10 caused stable jumps to revert; `RAMPJUMP_REACQUIRE_MAX`: 20 → 12
- `LAP_TIMEOUT`: 45 → 60
- New pad tiers: `Boost50`, `Brake50` (in `PadValueUtils`, `Types`, `ActionValidator`)
- Lever bounds expanded: RampJump angle max 40→60, gap max 24→40; CrestDip height max 18→30; Chicane amplitude max 18→24
- New constants: `ENDURANCE_ATTEMPT_BUDGET = 12`, `ENDURANCE_LAP_TIME_BUDGET_RATIO = 0.40`, `HOTFIX_MAX_ATTEMPTS = 5`
- Test suite refactor: deleted TestPhase7/8/10/12/12_5; rewrote TestPhase4/6; extended TestPhase5/11/13; cleaned TestDispatcher
- Added `TestPhase14.luau` golden regression coverage for tuned RampJump/Chicane/CrestDip profiles plus the sector-2 jump JobRunner path

**Chunk B — HotfixAgent + upstream retry:**
- `HotfixAgent.luau` — emergency repair loop for committed sectors that start failing
- `JobRunner.luau` — upstream retry (first occurrence) + hotfix trigger (second consecutive); `_pendingRequest` queue; `getPendingRequest`/`clearPendingRequest` exports
- `UIState.luau` — endurance/hotfix attributes: `endurance_mode_active`, `endurance_hotfix_active`, `endurance_hotfix_sector`, `endurance_terminal`, `endurance_lap_count`, `endurance_attempt_budget_used/total`
- `HUDRegistry.luau` — `topLeftStroke` exposed for hotfix danger styling
- `HUD.client.luau` — delayed binding for `AutoTrack_SetBaseline` / `AutoTrack_SetLLMConfig` so the client no longer logs infinite-yield warnings at boot
- `StatusPanel.luau` — failure banner opacity reduced so failures stay readable without hiding the car
- `VerifierController.luau` — limited in-air orientation torque restored so jumps are not artificially destabilized by zero airborne attitude control

**Demo commands added:**
- `/demo extreme` — toggle: applies Boost50 ingress (sector 2) + max RampJump (sector 3) + max CrestDip (sector 7) for in-game inspection; second call restores. No lap runs.
- `/demo hotfix` — plants impossible RampJump in sector 3, submits a job targeting sector 4; triggers upstream failure → retry → HotfixAgent sequence.

### Proven post-retune validation

- `make test TEST=phase5_unit` passes
- `make test TEST=phase14_integration` passes
- `make test TEST=phase4` passes

### Hard-won bugs fixed during Phase 14 work

**130 studs/s verifier speed destabilized baseline obstacle tuning:**
- Problem: the faster verifier pushed RampJump and CrestDip outside the stable envelope and made the repair loop churn around tumble vs under-air thresholds.
- Fix: retune back to 100 studs/s, keep the expanded obstacle ranges/pad tiers, and record passing golden obstacle profiles in `TestPhase14`.

**Corner braking regression during the 130 studs/s experiment:**
- Problem: old `CORNER_SPEED_FACTOR=0.25` at 130 studs/s gave 32.5 corner speed, higher than pre-14 (80×0.33=26.4). Car flew off sector 5 arc.
- `CORNER_BRAKE_LOOKAHEAD=8` made it worse — with only 2 waypoints per plain straight, lookahead of 8 covered the entire track; car drove at 26 studs/s everywhere.
- Fix: remove lookahead entirely, set `MaxForce=math.huge` (instant decel), lower factor to 0.20. Corner sector boundary change alone is sufficient.

**RampJump integrity tightening overshot the real stable envelope:**
- Problem: `RAMPJUMP_MIN_AIR_DISTANCE=10` rejected jumps that were visually stable and traversable under the retuned 100 studs/s verifier, which caused revert loops even after the geometry was behaving.
- Fix: restore limited airborne attitude control and lower the airtime floor to 4.5, then pin a passing sector-2 golden jump in `TestPhase14`.

**Upstream retry state machine crash:**
- Problem: after first upstream failure, `nextAction=nil; continue` loops back to top of while which calls `sm:transition("ApplyWorkingSector")`. State machine was in `EvaluateResult` which only allows `Commit` or `AnalyzeFailure` — illegal transition threw, pcall caught debug.traceback, HUD showed "system failure: ServerScriptService...".
- Fix: add `sm:transition("AnalyzeFailure"); sm:transition("ApplyRepair")` before the `continue`.

### Remaining chunks (not started)

- **C** — ContinuousLapRunner
- **D** — OrchestratorAgent (`/demo endurance`)
- **E** — HUD hotfix red border, lap counter, "ENDURANCE FAILED" terminal display

## Recommended next focus

- Do **not** reopen Chunk A tuning unless a new regression proves the golden obstacle profiles wrong.
- Resume with Chunk C (`ContinuousLapRunner`) using the current passing suites as the physics baseline.
- Preserve the current regression contract before adding endurance behavior:
  - `make test TEST=phase5_unit`
  - `make test TEST=phase14_integration`
  - `make test TEST=phase4`

## Standing task for all follow-on agents

After completing your session work, check whether `plans/agent-handoff.md` has grown beyond ~100 lines. If so:
1. Move any new durable lessons into the "Hard-won invariants" section of `AGENTS.md`
2. Trim historical narrative from this file — completed-phase lessons are already in the code
3. Keep this file to phase status + current WIP only
