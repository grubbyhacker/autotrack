# Phase 6 — CI Orchestrator State Machine (No-LLM Vertical Slice)

## Context

Phases 1–5 built every building block: track generator, sector registry/applier/rollback, semi-rail verifier, mechanic builders + pads, metric collection, and integrity evaluators producing `(RunResult, hints)`. Phase 6 wires these into the PRD §7 propose → apply → verify → evaluate → (repair | commit | revert) loop, driven by a user text submission — without any LLM involvement (PRD §19 vertical slice).

Outcome: a user can type `"add a jump in sector 3"`, the system parses it, produces a hardcoded initial proposal, runs a visible full-lap simulation, and either commits the new sector state, applies up to 5 single-lever repairs, or rolls back to the prior committed state. All transitions are traceable and testable.

The Phase 7 LLMAdapter will later replace `MinimalProposer` behind the same function signatures.

---

## Final plan (file-level change list)

### New files

- **`src/orchestrator/RuntimeContext.luau`** — process singleton that holds boot-produced live state so `JobRunner.submit` can access it on a later frame. Required because `Main.server.luau` today holds `sectors`, `car`, `canonicalStart`, and `baselineLapTime` only as script locals.
  - API: `init({sectors, car, canonicalStart, baselineLapTime})`, `getSectors()`, `getSectorById(id)`, `getCar()`, `getCanonicalStart()`, `getBaselineLapTime()`, `isReady()`.
  - Matches the singleton-holder convention already used by `VerifierCar`.

- **`src/orchestrator/MinimalProposer.luau`** — no-LLM stand-in for `LLMAdapter`. Same return shapes so the Phase 7 swap is drop-in.
  - `initial(request): (SectorState?, err?)` — `params = LevelMappings.DEFAULTS[mechanic]` with a small deterministic qualifier-biasing table (tall/long/short/steep/gentle/tight/wide/narrow/shallow); pads default to `None`; version carried from `SectorRegistry.getCommitted(sector_id).version`.
  - `repair(packet): (AgentAction?, explanation?, err?)` — hint-driven deterministic rule table per mechanic (first match wins). Covers: RampJump (not-airborne → +ramp_angle / +ramp_length / ingress Boost; reacquire failed → −ramp_angle / egress Brake; gap below min → +gap_length; downstream → egress Brake), Chicane (amplitude/curvature low → +amplitude; local exec failure → +transition_length or ingress Brake; downstream → +corridor_width), CrestDip (vertical displacement low → +height_or_depth; reacquire fail → +radius or egress Brake). **Repeat-action guard**: if top-rule choice equals `packet.last_action`, fall through to next rule.

- **`src/orchestrator/TestPhase6.luau`** — unit + integration suite (see Test plan below).

### Modified files

- **`src/orchestrator/Main.server.luau`** (src/orchestrator/Main.server.luau:20–60) — after the baseline lap resolution, call `RuntimeContext.init({...})`. No other boot logic changes.

- **`src/orchestrator/JobRunner.luau`** — full implementation. Use `JobLock` (not the local `_busy`); remove `_busy`. Drive `JobStateMachine` through every transition. Keep `_lastJob: CIJob?` in module scope for test inspection. Public API: `submit(rawText): (ok, reason?)`, `isBusy(): boolean`, `getLastJob(): CIJob?`.

- **`src/orchestrator/AttemptRunner.luau`** — rewrite to a params-table signature:
  ```
  AttemptRunner.run({
    workingState, action?, targetSectorId,
    entryFrame, exitFrame,
    sectors, car, canonicalStart,
    onSectorChange?
  }): (RunResult, hints: {string}, updatedState: SectorState)
  ```
  Sequence: clone `workingState`; if `action`, apply via `ActionValidator.validateAction` then mutate clone; `SectorApplier.apply(clone, entryFrame, exitFrame)`; build `stateOverrides` from `SectorRegistry.getStraights()` filtered to `mechanic == "Chicane"` plus `[targetSectorId] = clone`; `TrackGenerator.getLapPath(sectors, overrides)`; `VerifierCar.reset(canonicalStart)`; `VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, onSectorChange, targetSectorId)` (see below); `LapEvaluator.evaluate(rawResult.failure, clone, rawResult.metrics, targetSectorId)` → return.

- **`src/orchestrator/JobStateMachine.luau`** — add `LEGAL_TRANSITIONS` table and assert in `:transition(next)`. Table:
  ```
  Idle → ParseRequest
  ParseRequest → RejectRequest | AcquireTrack
  RejectRequest → Idle
  AcquireTrack → RejectRequest | GenerateInitialProposal
  GenerateInitialProposal → ApplyWorkingSector | RejectRequest
  ApplyWorkingSector → RunVerification
  RunVerification → EvaluateResult
  EvaluateResult → Commit | AnalyzeFailure
  AnalyzeFailure → ApplyRepair | Revert
  ApplyRepair → ApplyWorkingSector
  Commit → Idle
  Revert → Idle
  ```

- **`src/orchestrator/TestRunner.server.luau`** — add `phase6`, `phase6_unit`, `phase6_integration` dispatch entries.

- **`src/agent/RequestParser.luau`** — implement `parse(rawText, requestId)`. Deterministic, no LLM. Steps: lowercase + trim → extract `sector%s*(%d+)` matches (reject on 0 distinct or >1 distinct) → validate sector ∈ `{2,3,4,7,8,9}` → longest-match mechanic synonym scan from `LevelMappings.MECHANIC_SYNONYMS` (reject on 0 or >1 distinct canonical) → extract qualifier words from a small curated set → return `Request`. Exit error strings map 1:1 to PRD §3.4 rejection classes.

- **`src/verifier/VerifierController.luau`** (src/verifier/VerifierController.luau:71,212,225) — **bug fix confirmed in this phase**: add optional `targetSectorId: number?` parameter to `runLap`; thread it into both `MetricCollector.finalise(...)` calls (failure path and success path). Keeps backward compatibility because both existing callers (`Main.server.luau` baseline and TestPhase3/4/4_5 tests) omit it — `finalise` falls back to `currentSectorId or 1` when the target is nil, matching current behavior exactly.

- **`plans/agent-handoff.md`** (post-implementation) — append Phase 6 lessons learned and flip Phase 6 status to Complete.

---

## JobRunner.submit() flow (definitive)

```
if JobLock.isHeld(): reject "busy"
sm.transition("ParseRequest")
request, err = RequestParser.parse(rawText, id)
if not request:
  sm.transition("RejectRequest"); sm.transition("Idle"); return false, err

if not JobLock.tryAcquire():
  sm.transition("RejectRequest"); sm.transition("Idle"); return false, "busy"
sm.transition("AcquireTrack")

targetId = request.parsed.sector_id
sector = RuntimeContext.getSectorById(targetId)
priorCommitted = SectorRegistry.getCommitted(targetId)
Tracer.log("job_start id=%s sector=%d mechanic=%s")

sm.transition("GenerateInitialProposal")
state, perr = MinimalProposer.initial(request)
if not state:
  sm.transition("RejectRequest"); JobLock.release(); sm.transition("Idle")
  return false, perr
state.version = priorCommitted.version    -- bumped at commit only

job = CIJob{...}
attemptIndex = 0
lastAction = nil

loop:
  sm.transition("ApplyWorkingSector")
  sm.transition("RunVerification")
  Tracer.log("attempt index=%d ...")
  (result, hints, nextState) = AttemptRunner.run{...}
  state = nextState

  sm.transition("EvaluateResult")
  push job.attempts

  if result.success:
    sm.transition("Commit")
    state.version = priorCommitted.version + 1
    SectorRegistry.commit(state)
    Tracer.log("commit sector=%d version=%d")
    Tracer.log("job_end id=%s status=committed")
    JobLock.release(); sm.transition("Idle")
    _lastJob = job; return true

  sm.transition("AnalyzeFailure")
  if attemptIndex >= Constants.MAX_REPAIR_ATTEMPTS:
    sm.transition("Revert")
    SectorRollback.revert(targetId, sector.entry, sector.exit)
    Tracer.log("revert sector=%d attempts=%d")
    Tracer.log("job_end id=%s status=reverted")
    JobLock.release(); sm.transition("Idle")
    _lastJob = job; return true

  packet = LapEvaluator.buildFailurePacket(request, state, attemptIndex,
           lastAction, result, (result.failure and result.failure.sector_id) or targetId, hints)
  sm.transition("ApplyRepair")
  action, explanation, rerr = MinimalProposer.repair(packet)
  if not action or not ActionValidator.validateAction(action, state.mechanic):
    sm.transition("Revert"); SectorRollback.revert(...); release; return true
  lastAction = action; attemptIndex += 1
  Tracer.log("repair attempt=%d action=%s explanation=%s")
  -- next loop iteration
```

Wrap the loop body in `pcall`; on thrown error, revert + release + return `(false, "system failure: "..err)`.

---

## Trace lines (extends existing set)

| Line | Source |
|---|---|
| `job_start id=<id> sector=<N> mechanic=<M>` | JobRunner, after lock acquired |
| `job_reject reason=<r> raw='<text>'` | JobRunner, parse/lock reject |
| `attempt index=<i> sector=<N> mechanic=<M>` | JobRunner, per attempt |
| `repair attempt=<i> action=<summary> explanation=<text>` | JobRunner, after MinimalProposer.repair |
| `commit sector=<N> version=<v>` | JobRunner, after SectorRegistry.commit |
| `revert sector=<N> attempts=<n>` or `revert reason=<r>` | JobRunner, after SectorRollback.revert |
| `job_end id=<id> status=<committed\|reverted>` | JobRunner, final terminal line |

---

## Test plan (`TestPhase6.luau`)

### Unit (`runUnit`, SkipBootBaseline-compatible, no sim)

- `parser_accept_basic` — `"Add a jump in sector 3"` → sector=3, RampJump
- `parser_accept_synonyms` — chicane / s-curve / crest / dip / ramp jump
- `parser_qualifiers_extracted` — `"really tall jump in sector 4"` qualifiers ⊇ {"really","tall"}
- `parser_reject_empty`, `parser_reject_no_sector`, `parser_reject_multi_sector`, `parser_reject_corner`, `parser_reject_ambiguous`, `parser_reject_unsupported`
- `proposer_initial_defaults` — no qualifiers → params == `LevelMappings.DEFAULTS[mechanic]`
- `proposer_initial_bias` — `"tall"` → ramp_angle > default
- `proposer_repair_rampjump_notAirborne` — hint "verifier never became airborne" → `SetNumericLever` on ramp_angle
- `proposer_repair_chicane_amplitude_low` — hint → lever=amplitude
- `proposer_repair_crestdip_displacement_low` — lever=height_or_depth
- `proposer_repair_downstream_pads_brake`
- `proposer_repair_no_repeat` — `last_action` equals top-rule → returns a different action
- `statemachine_legal` — chain Idle → … → Commit passes
- `statemachine_illegal` — Idle → Commit raises
- `runtime_context_roundtrip` — after init, getters return passed values

Use synthetic `FailurePacket`/`SectorState`/`Request` factories mirroring `TestPhase5`.

### Integration (`runIntegration`, requires baseline / full boot)

- `submit_rejects_empty` — `submit("")` → `(false, "empty request")`, no `job_start` in trace
- `submit_rejects_busy` — acquire `JobLock` manually, call `submit(...)` → busy rejection
- `rampjump_initial_success` — defaults already satisfy integrity → `job_end status=committed`; `SectorRegistry.getCommitted(3).mechanic == "RampJump"`; version=1
- `rampjump_repair_once` — seed scenario where initial proposal fails air_distance but one repair fixes it (pre-override initial state to ramp_angle=10 via a test-only hook or pick a qualifier that forces it) → attempts ≥ 2 and `final_status=committed`
- `exhaustion_reverts` — craft a request that cannot be repaired in 5 tries → `final_status=reverted`; `SectorRegistry.getCommitted(target)` unchanged; Sector_0N workspace folder has only flat geometry
- `commit_bumps_version` — submit successful job twice on same sector → versions 1, 2
- `sector_replacement` — commit RampJump then submit Chicane on same sector → final mechanic=Chicane, version=2

`Tracer.clear()` at the start of each integration test; assert on `Tracer.getLog()` for bracketing.

### Test dispatch

`TestRunner.server.luau`:
```
elseif cmd == "phase6" then require(...).run()
elseif cmd == "phase6_unit" then require(...).runUnit()
elseif cmd == "phase6_integration" then require(...).runIntegration()
```

---

## Sequenced implementation order

1. `RuntimeContext.luau` + wire into `Main.server.luau`.
2. `RequestParser.parse` + unit tests (parser_*).
3. `JobStateMachine` transition guards + unit tests.
4. `MinimalProposer.luau` + unit tests (proposer_*).
5. `VerifierController.runLap` targetSectorId threading (the bug fix).
6. `AttemptRunner.run` with params-table signature.
7. `JobRunner.submit` full loop + new trace lines.
8. `TestPhase6.luau` (assemble all tests + register in `TestRunner.server.luau`).
9. Run Phase 5 suite to confirm no regressions, then `phase6_unit`, then `phase6_integration` (full boot).
10. Update `plans/agent-handoff.md` with Phase 6 completion + lessons learned.

---

## Critical files

- `src/orchestrator/JobRunner.luau` — main loop
- `src/orchestrator/AttemptRunner.luau` — one-attempt runner
- `src/orchestrator/JobStateMachine.luau` — transition guards
- `src/orchestrator/Main.server.luau` — RuntimeContext publication
- `src/orchestrator/RuntimeContext.luau` — new
- `src/orchestrator/MinimalProposer.luau` — new, hint-driven no-LLM policy
- `src/orchestrator/TestPhase6.luau` — new
- `src/orchestrator/TestRunner.server.luau` — dispatch additions
- `src/agent/RequestParser.luau` — deterministic parser
- `src/verifier/VerifierController.luau` — targetSectorId threading

## Reused building blocks (do NOT reimplement)

- `TrackGenerator.getLapPath(sectors, stateOverrides?)` — overrides map supports per-attempt Chicane path regeneration
- `TrackGenerator.canonicalStart()` — safe anywhere
- `SectorApplier.apply(state, entryFrame, exitFrame)` — caller supplies frames (from `RuntimeContext.getSectorById`)
- `SectorRollback.revert(sector_id, entryFrame, exitFrame)` — reads committed state internally; does not need prior snapshot
- `SectorRegistry.{getCommitted, getStraights, commit}` — commit does NOT bump version; JobRunner must set `state.version = prior + 1` immediately before commit
- `VerifierCar.{spawn, reset}` — already singleton
- `VerifierController.runLap(...)` — returns raw `RunResult`; does not call LapEvaluator
- `LapEvaluator.evaluate(lapFailure?, state, metrics, targetSectorId) → (RunResult, hints)`
- `LapEvaluator.buildFailurePacket(request, state, attemptIndex, lastAction, result, failureSector, hints)`
- `ActionValidator.validateAction(action, mechanic)` — use to gate proposer output
- `LevelMappings.{DEFAULTS, NUMERIC_LEVERS, MECHANIC_SYNONYMS}`
- `Constants.MAX_REPAIR_ATTEMPTS` (5), `Constants.LAP_TIMEOUT` (120s)
- `JobLock.{tryAcquire, release, isHeld}` — the single global job lock; remove JobRunner's local `_busy`
- `Tracer.{log, getLog, clear}`

---

## Verification (end-to-end)

1. In Studio, with `AutoTrack_SkipBootBaseline = false`, start Play and wait for boot baseline `lap_complete`.
2. `phase5` — regression guard for integrity evaluators.
3. Set `AutoTrack_SkipBootBaseline = true`, restart Play, run `phase6_unit` — should PASS without any lap.
4. Set `AutoTrack_SkipBootBaseline = false`, restart Play, run `phase6_integration`:
   - watch the visible lap for each scenario
   - confirm `[TRACE] job_start … attempt … (repair …)* (commit|revert) … job_end` bracketing in `get_console_output`
   - confirm `SectorRegistry` state post-job matches expectation (committed mechanic + version, or unchanged on revert)
5. Stop Play.

---

## Open design notes (decided)

- **MetricCollector target-sector fix**: included in Phase 6 (user-confirmed). Two-line change to `VerifierController.runLap` + threading through `MetricCollector.finalise`.
- **Repair policy**: hint-driven deterministic rules per mechanic (user-confirmed).
- Qualifier biasing table: stub values (reasonable defaults); tunable later; not load-bearing for Phase 6 since repair policy is the primary driver after the initial apply.
- Parser strictness: permissive — any text with a sector ID and a canonical mechanic synonym is accepted. Stricter heuristics deferred to post-LLM.
- Boot order: `RuntimeContext.init` is called only after the baseline lap finishes, so `JobRunner.submit` cannot fire during baseline.
- CIJob history: keep only `_lastJob` in-memory for Phase 6; expand when Phase 8 UI needs more.

---

## Risks

- MinimalProposer may not converge inside 5 attempts for pathological initial states. Mitigation: integration tests use defaults known to pass on the target sector, and separately test a deliberately-unrepairable case to exercise exhaustion.
- Chicane lap-path override must pick up committed Chicanes in *other* sectors (not just the target) — covered by `AttemptRunner` building overrides from `SectorRegistry.getStraights()`.
- Session accumulation: sequential committed jobs persist in `SectorRegistry`. Integration tests must avoid order dependence or explicitly sequence.
- `Tracer._log` grows unbounded; fine for Phase 6, flag for Phase 8 UI.
