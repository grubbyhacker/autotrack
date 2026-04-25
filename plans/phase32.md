# Phase 32+ — Incremental Type Safety Roadmap (Post-Phase 31)

## Status

Milestones 32, 33, 34, and 35 are complete.

Implemented in Milestone 32:

- added `src/orchestrator/TestSuiteRunner.luau` as a lightweight `/test` dispatch seam
- removed the direct `CommandRouter -> TestDispatcher` dependency so runtime command/job modules no longer depend on `TestPhase*` modules through the analyzer graph
- registered the real suite dispatcher from `TestRunner.server.luau` and `StudioTestBootstrap.server.luau` so existing runtime/test entrypoints stay intact
- updated `TestPhase22.luau` to stub the seam directly instead of monkey-patching `TestDispatcher`, eliminating the remaining `TestDispatcher <-> TestPhase22` analyzer cycle

Verification used for Milestone 32:

- `make fmt-check`
- `make typecheck`
- `make lint`
- `make phase22_command_surface`
- `make typecheck-report` with no remaining `Cyclic module dependency` diagnostics

Implemented in Milestone 33:

- added `Types.TargetRuntimeMetrics` for mechanic runtime-integrity evaluators and `Types.TargetTelemetrySnapshot` for raw target-sector metric snapshots
- updated `RampJumpIntegrity.evaluateRuntime`, `ChicaneIntegrity.evaluateRuntime`, and `CrestDipIntegrity.evaluateRuntime` to consume the narrow target-runtime contract instead of full `RunMetrics`
- typed `MetricCollector.getTargetMetrics()` as the raw target snapshot surface and added an explicit projection in `VerifierController` from that snapshot into the prefixed integrity-evaluator contract
- left finalized lap/scoring/failure surfaces on full `RunMetrics`, so behavior and scoring inputs remain unchanged outside the runtime-integrity boundary

Verification used for Milestone 33:

- `make fmt-check`
- `make typecheck`
- `make lint`
- `make phase18`
- `make typecheck-report` with no remaining `RunMetrics` shape-mismatch diagnostics

Implemented in Milestone 34:

- refactored `Types.ParsedRequest` into explicit `MechanicParsedRequest | PadParsedRequest` tagged unions so mechanic requests always carry `mechanic` and pad requests always carry `pad_side` / `pad_value`
- refactored `Types.OrchestratorDecision` into explicit `OrchestratorLoopDecision | OrchestratorSubmitDecision` variants, with proposal-path decisions now using `action = "submit_request"`
- normalized `LLMAdapter.validateOrchestratorDecision()` into the explicit submit/loop contract while preserving legacy provider compatibility by treating missing `action` as `submit_request`
- updated `MinimalOrchestrator`, `OrchestratorAgent`, `EnduranceObjective`, `RequestParser`, `JobRunner`, and hotfix/test fixtures to use the discriminated contracts directly
- tightened `MinimalProposer` repair candidate typing to stay on `AgentAction`-safe arrays and normalized pad-strength helper outputs back onto the `PadValue` union

Verification used for Milestone 34:

- `make fmt-check`
- `make typecheck`
- `make lint`
- `make phase14_5`
- `make phase19`
- `make phase20`
- `make phase23`
- `make typecheck-report` with no remaining proposer/orchestrator union-discriminator diagnostics

Implemented in Milestone 35:

- fixed remaining nilability and non-nil narrowing issues in `FailureMarker`, `VerifierController`, `LLMTraceJournal`, and `Main.server`
- cleared the residual analyzer-only static blockers in `CommandRouter` and `JobStateMachine`
- added/standardized typed `OrchestratorContext` fixture builders in `TestPhase14` and `TestPhase14_5` so required `memory` state is always present
- left production contracts strict; fixture cleanup happened at the test-builder boundary instead of by weakening shared types

Verification used for Milestone 35:

- `make fmt-check`
- `make typecheck`
- `make lint`
- `make boot_smoke`
- `make phase14`
- `make phase14_5`
- `make phase19`
- `make phase20`
- `make phase22_command_surface`
- `make typecheck-report`

## Summary

This plan defines the next incremental type-safety milestones after Phase 31.
The goal is trustworthy, architecture-improving Luau typing in small slices, not a bulk `--!strict` rollout.

Baseline from current `make typecheck-report` backlog:

- 113 unique diagnostics (deduped by `path:line:col:message`)
- dominant classes:
  - cyclic module dependencies (`56`)
  - `RunMetrics` shape mismatches (`23`)
  - nilability / optional-number mismatches (`10`)
  - `SetAction` union exactness mismatches (`10`)
  - `OrchestratorContext` fixture shape mismatches (`4`)

## Error Buckets and Ownership

### Bucket A: Runtime/test dependency cycles

- Class: definition/design problem with test-coupling impact
- Primary symptom: `Cyclic module dependency`
- Typical chain: `CommandRouter -> TestDispatcher -> TestGates/TestPhase* -> JobRunner -> CommandRouter`
- Why it matters: analyzer sees graph-level architectural coupling; this is not a one-off annotation issue.

### Bucket B: `RunMetrics` overreach

- Class: definition/design problem plus test-fixture shape problem
- Primary symptom: target-runtime snapshots rejected as `RunMetrics`
- Why it matters: runtime integrity evaluators currently accept a type that includes unrelated full-lap fields (`lap_time`, `slowdown_ratio`, etc.), forcing noise in runtime code and tests.

### Bucket C: Broad union contracts in production code

- Class: production-code problem driven by broad shared types
- Primary symptom:
  - optional pad/mechanic fields not narrowed enough in proposer flows
  - `AgentAction` candidate lists inferred as loose `{ any }` tables
  - actionable orchestrator decisions carrying optional fields needed as required by call sites
- Why it matters: key codepaths lose type precision exactly where behavior decisions are made.

### Bucket D: Nilability and fixture hygiene leftovers

- Class: mostly production-code cleanup, plus test-fixture cleanup
- Primary symptom:
  - `number?` passed to `number` call sites
  - guaranteed non-nil values not narrowed before return/use
  - fixture literals drifting behind required shared context fields
- Why it matters: these are small but high-signal errors that hide real regressions when left noisy.

## Shared Types to Refine First

### `RunMetrics`

- Current issue: too broad for runtime-integrity inputs; mixes final lap metrics with mechanic-runtime slices.
- Direction: keep `RunMetrics` for finalized lap result surfaces; introduce a narrow `TargetRuntimeMetrics` (or equivalent) for `evaluateRuntime` APIs and target-snapshot helpers.

### `ParsedRequest`

- Current issue: shape is optional-heavy despite `request_kind` discriminator.
- Direction: switch to a true tagged union:
  - Mechanic request shape (required `mechanic`)
  - Pad request shape (required `pad_side` + `pad_value`)

### `OrchestratorDecision`

- Current issue: one broad shape covers both `begin_loop` and actionable decisions, leaving required values optional at call sites.
- Direction: split into decision variants (loop action vs submit action) and narrow before request-text generation / submit path.

### `OrchestratorContext` fixture creation

- Current issue: test literals omit required fields (notably `memory`) and drift from production contract.
- Direction: keep strict production contract; add typed test builders/default constructors instead of weakening the shared type.

## Milestones

### Milestone 32 — Break analyzer-visible runtime/test cycles

In scope:

- decouple test-dispatch requires from runtime command/job modules so runtime graph does not depend on `TestPhase*` modules
- preserve current runtime and test behavior/entrypoints

Green target for this milestone:

- remove cyclic-dependency diagnostics from `make typecheck-report`

Outcome:

- completed as planned; the cycle bucket is removed without adding suppressions or widening runtime/test coupling

Out of scope:

- `RunMetrics` contract redesign
- broad nilability cleanup
- strictness migration

### Milestone 33 — Split runtime metric contracts cleanly

In scope:

- add narrow runtime-evaluator metrics type (`TargetRuntimeMetrics` name can vary)
- update integrity runtime evaluator signatures to the narrow type
- keep full lap evaluator and scoring surfaces on `RunMetrics`
- adjust runtime callers and test fixtures accordingly

Green target for this milestone:

- remove `RunMetrics` shape-mismatch diagnostics in both production and tests

Outcome:

- completed as planned; runtime evaluators now consume `TargetRuntimeMetrics`, collector snapshots are typed separately, and the `RunMetrics` mismatch bucket is removed without changing scoring or telemetry behavior

Out of scope:

- scoring formula changes
- telemetry behavior changes unrelated to typing contracts

### Milestone 34 — Tighten proposer/orchestrator discriminated unions

In scope:

- refactor `ParsedRequest` and `OrchestratorDecision` to explicit tagged unions
- tighten `MinimalProposer` candidate typing so repair actions remain `AgentAction`-safe without broad casts
- remove ambiguous optional-string/optional-mechanic flow errors

Green target for this milestone:

- eliminate current proposer/orchestrator union exactness and optional discriminator errors

Outcome:

- completed as planned; proposal/orchestrator flows now use explicit tagged unions end-to-end, runtime submit decisions are no longer represented by missing `action`, and the proposer/orchestrator union bucket is removed from `make typecheck-report` without changing repair or orchestration policy behavior

Out of scope:

- proposal/repair policy tuning
- behavior changes in mechanic heuristics

### Milestone 35 — Nilability + fixture hygiene finishing pass

In scope:

- fix production nilability mismatches (`number?`/non-nil returns/string formatting assumptions)
- add/standardize typed test context builders for `OrchestratorContext` and similar shared fixtures
- clear residual small-format/pattern analyzer issues that are type-report blockers

Green target for this milestone:

- clear current nilability/context-fixture residue and leave report dominated by any truly new regressions only

Outcome:

- completed as planned; `make typecheck-report` now exits clean with no remaining backlog, and the last nilability, fixture-hygiene, and small analyzer-blocker residues were removed without broad casts or type weakening

Out of scope:

- repo-wide strict mode enablement
- suppressions or broad `any`-casts as a closure strategy

## Test and Acceptance Strategy

For each milestone:

- `make typecheck` remains green for the gated subset
- `make typecheck-report` is used as the backlog ratchet check
- no broad suppressions, no blanket casts, no mass `--!strict` edits

Milestone acceptance requires:

- the targeted error bucket is removed or materially reduced as specified
- no backslide in previously-green hygiene gates (`fmt-check`, `lint`, existing `typecheck` subset)

## Assumptions and Defaults

- This plan optimizes for architecture/readability improvements first, raw error count second.
- Shared-type refinements should increase domain clarity rather than making contracts looser.
- Tests are part of type-safety quality; they are not excluded from report scope.
