# Plan: Update 14.5 — Endurance Intelligence, Objective Model, and HUD

## Status

- Complete.
- Phase 14.5 does not change physics/integrity behavior.
- Phase 14.5 focuses on orchestrator policy and visibility:
  1) prevent repeated bad obstacle patterns via session memory,
  2) define a formal end-to-end objective for decisions,
  3) overhaul the HUD around that objective and the decision history.

## Final implementation notes

- `OrchestratorAgent` now carries bounded `attempt_history`, per-sector attempt counts, repeat pressure, and `track_intent` through each loop.
- `EnduranceObjective` is the scoring boundary for candidate ranking and repeat avoidance.
- `MinimalOrchestrator` remains deterministic but now skips hot repeated signatures when a fresh planned sector exists.
- HUD telemetry is surfaced through replicated `UIState` orchestrator attributes and rendered in the existing client HUD without changing the command flow.
- A maintained targeted gate now exists: `make test TEST=phase14_5`.

## Executive Findings (current state)

1) **Orchestrator LLM state awareness**
- `LLMAdapter.orchestrate(context)` is already wired into `OrchestratorAgent`.
- Current context includes:
  - editable sector IDs,
  - per-sector current state + score,
  - budget + attempt budget,
  - `last_result` from previous job.
- Missing: session-memory of prior decisions/attempt outcomes per sector and per mechanic pattern.

2) **Repair-agent history**
- `JobRunner` already passes `job.attempts` into `LLMAdapter.repair(packet, job.attempts)`.
- `AttemptRecord` currently carries `attempt_index`, `action`, `proposed_state`, `result`, `hints`.
- Repair history is therefore available, but it is **not yet normalized into a global orchestration memory**.

3) **Orchestrator motivation**
- Current prompt says "maximize spectacle and score" with budget guardrails.
- There is no encoded formal objective with hard tie-breaks, novelty/reuse penalties, or reliability weighting.
- `MaxLoop` starts when budget is reached or context says `begin_loop`, so behavior can drift toward repetition under failure/repair noise.

---

## Phase 14.5 Scope and Deliverables

### 1) Orchestrator Memory (must-have)

#### 1.1 Schema
- Extend orchestrator types:
  - `OrchestratorAttempt` (new): sector, mechanic, params_hint, normalized params summary, outcome, score, slowdown, failure signature, repair iterations, decision index, timestamp.
  - add `history` (bounded, latest N entries, newest-first) to `OrchestratorContext`.
- Keep replay compact: only send JSON-safe summary, no live objects.

#### 1.2 Memory capture
- In `OrchestratorAgent.run` after each submitted job:
  - append one ledger entry from `lastResult` + `getLastJob()`.
  - compute derived summary fields:
    - `attempts_spent`
    - `repair_count` (from `job.attempts`)
    - `failure_signature` (type + normalized detail)
    - `reused_signature_count` per mechanic/sector/param-bucket.

#### 1.3 Memory surfaced to orchestrator
- Extend `buildContext` to include:
  - `attempt_history` (bounded)
  - `sector_attempt_counts`
  - `mechanic_repeat_pressure` (sector + mechanic signatures that should be deprioritized)
- For repaired failures, prefer storing a **deduplicated reason** (`"tumble@sector2/jump:long-high-gap"`) instead of raw strings.

#### 1.4 Minimal fallback
- `MinimalOrchestrator.decide` should still run:
  - when no LLM, obey fixed ordering but skip entries where signature heat is high and there are fresh alternate sectors/mechanics.
  - keep deterministic output so unit tests remain stable.

---

### 2) Formal Endurance Objective (must-have)

#### 2.1 Define objective module
- Add `src/orchestrator/EnduranceObjective.luau`.
- Define:
  - `CandidateScore` with fields:
    - `base_score_gain`
    - `track_sustainability`
    - `novelty_bonus`
    - `repeat_penalty`
    - `budget_risk_penalty`
    - `repair_complexity_penalty`
  - function `evaluateCandidate(context, candidate)` returning `CandidateScore + rationale`.

#### 2.2 Scoring rules to start
- Hard constraints:
  - skip candidates where `context.budget.over_budget == true` unless explicitly needed to recover structure.
- Objective (high-level):
  - maximize projected track score growth while keeping budget headroom and long-run reliability.
- Baseline scoring components:
  - projected track potential (`score` from `OrchestratorSectorSnapshot` plus open-slot opportunity)
  - completion risk (how often this sector failed recently)
  - novelty (avoid exact repeat signatures)
  - repair pressure (if prior repair count on mechanic+sector exceeds threshold, down-rank)
  - optional continuity reward for unfilled/underperforming sectors.

#### 2.3 Orchestrator prompt contract update
- Update `OrchestratorPromptBuilder`:
  - include compact objective card.
  - explicitly ask the model to propose only candidates within top objective bands.
  - include repeated-signature list and last known failure signatures per sector.

#### 2.4 Persisted session goal
- After each job, compute projected objective delta and stash to context as `track_intent`:
  - `target_total_score`
  - `target_budget_used`
  - `diversity_pressure` for sectors/mechanics.

---

### 3) HUD Overhaul (must-have)

#### 3.1 New orchestration telemetry attributes
- Add to `UIState`:
  - `orchestrator_objective_total`, `orchestrator_budget_target`, `orchestrator_budget_headroom`
  - `orchestrator_decision_index`, `orchestrator_last_decision`, `orchestrator_last_rationale`
  - `orchestrator_memory_depth`
  - `orchestrator_repeat_penalties`
  - `orchestrator_failure_signature`, `orchestrator_reliability_index`
- Keep defaults set in `UIState.init`.

#### 3.2 HUD sections
- Replace current Endurance row composition with explicit objective/status panel:
  - **Row A**: phase + current objective + budget headroom
  - **Row B**: active sector target + rationale + repeat pressure level
  - **Row C**: last 3 decisions with outcomes (committed/reverted/fail)
- Keep existing command input controls to avoid regressions.

#### 3.3 Hotfix/endurance summary integration
- In `StatusPanel`/`HUDRegistry`, add a compact "Decision Ledger" list of latest 3 orchestrator steps.
- Ensure hotfix/terminal colors remain red-dominant and legible.

---

## Test and gating plan

### Unit/hosted tests to add
1) `src/orchestrator/TestPhase14_5.luau` (new)
- `orchestrator_buildContext_includes_history`
- `orchestrator_history_hashes_repeat_signatures`
- `orchestrator_objective_skips_repeated_failed_signature`
- `minimal_orchestrator_uses_context_fallback_without_adding_nondeterminism`
- `hud_state_defaults_include_orchestrator_objectives`
- `orchestrator_runs_until_begin_loop_or_budget_exhaustion_with_history`

### Integration
2) Extend `TestPhase14.runUnit` with orchestrator memory assertions.
3) Add `phase14_5` commands if test runner separation helps:
- `TestDispatcher` entry + `Makefile` target.
- `tools/test_bridge_config.json` include suite if needed.

### Runtime acceptance (manual)
4) Run 4x loops with `/demo endurance` under real LLM and verify:
- same exact mechanic config is not re-proposed after repeat-punished failures,
- objective text visibly changes after each lap sequence,
- track score/budget trend is visible in HUD and does not stall into repeated loops.

## Rollback plan
- If repeat memory causes stagnation, gate it behind a weight scalar in `EnduranceObjective` default 0.
- Keep `MinimalOrchestrator` and current prompt fallback available.
- If HUD changes destabilize input flow, only keep telemetry updates (non-visual) and defer visual reshuffle.
