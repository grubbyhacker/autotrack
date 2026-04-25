# Phase 36 — Quality Gate Promotion and Builder Consolidation

## Status

Planned.

Phase numbering resumes at `36` because `plans/phase32.md` was used as a roadmap slice that covered Milestones `32` through `35`. Do not backfill separate `phase33.md`, `phase34.md`, or `phase35.md` files.

## Goal

Turn the now-green static-analysis state into a maintained project contract, and reduce duplicated raw-table construction at the request/orchestration/test-fixture boundaries.

This phase should stay contract-focused. It is not a mechanic-retune phase.

## Why This Slice Exists

Phase 32+ completed the type-safety backlog and left `make typecheck-report` green.

The next highest-leverage work is:

- making that green analyzer state harder to regress
- reducing repeated hand-built contract tables for `Request`, `DesignIntent`, `OrchestratorContext`, `AgentAction`, and related fixtures
- ratcheting strictness on a few boundary modules where the contracts are now stable

## Deliverables

### 1. Promote the Green Static Contract Into Maintained Tooling

Choose and implement the maintained gate for the full analyzer pass.

Acceptable outcomes:

- `make typecheck` grows to cover the current `typecheck-report` surface, or
- `make hygiene` / another clearly documented target becomes the required full static gate

Requirements:

- one maintained command must represent the authoritative full static contract
- the chosen gate must be documented in project docs / handoff
- implementation should avoid duplicate near-equivalent targets with unclear ownership

### 2. Add Shared Typed Builders for High-Churn Contract Shapes

Introduce small helper builders instead of repeated raw table literals.

Primary targets:

- parsed mechanic/pad request construction
- endurance design-intent construction
- orchestrator submit/loop decision construction
- `AgentAction` construction (`SetNumericLever`, `SetPad`)
- optional `RunMemory` / empty-memory helper if call sites still repeat it

Guidelines:

- keep builders small and explicit
- prefer stable boundaries (`src/common/` for shared production builders, `src/orchestrator/` for test-only factories)
- do not hide meaningful business rules inside convenience builders unless that rule is already canonical elsewhere

### 3. Add Test Factories for Shared Context Fixtures

Replace repeated hand-built context tables in tests with typed fixture helpers.

Primary targets:

- `OrchestratorContext`
- common endurance request/design-intent fixtures where repetition is still high

Requirements:

- fixture helpers should produce valid strict shapes by default
- tests may still override fields locally, but should not need to remember every required field
- production shared types must remain strict; do not weaken types to accommodate test literals

### 4. Ratchet `--!strict` Selectively on Stable Boundary Modules

After the builder/factory cleanup, promote a small number of low-risk modules to stricter checking.

Candidate modules:

- `src/agent/RequestParser.luau`
- `src/orchestrator/MinimalOrchestrator.luau`
- `src/orchestrator/EnduranceMemory.luau`
- `src/agent/LLMTraceJournal.luau`

Guidelines:

- upgrade only modules whose contracts are already narrow and stable
- do not do a repo-wide strict migration
- if a module still needs broad casts or awkward workarounds, defer it instead of forcing the upgrade

## Likely Files

Tooling / docs:

- `Makefile`
- `plans/agent-handoff.md`
- `plans/phase36.md`

Possible shared builder locations:

- `src/common/Types.luau`
- one new shared builder module under `src/common/`

Possible test-factory locations:

- one new helper under `src/orchestrator/`
- existing high-churn suites such as:
  - `src/orchestrator/TestPhase14.luau`
  - `src/orchestrator/TestPhase14_5.luau`
  - `src/orchestrator/TestPhase19.luau`
  - `src/orchestrator/TestPhase20.luau`
  - `src/orchestrator/TestPhase23.luau`

## Acceptance Criteria

- the project has one clearly documented authoritative full static-analysis gate
- `make typecheck-report` remains green throughout the phase
- duplicated raw-table construction is materially reduced at the targeted contract boundaries
- shared production types remain strict
- selected strictness ratchet modules stay green without broad `any` casts

## Verification

Static:

- `make fmt-check`
- `make typecheck`
- `make lint`
- chosen full static gate
- `make typecheck-report`

Likely suite coverage after builder migration:

- `make boot_smoke`
- `make phase14_5`
- `make phase19`
- `make phase20`
- `make phase22_command_surface`
- `make phase23`

## Out Of Scope

- gameplay/mechanic retuning
- new mechanics or schema expansion
- repo-wide `--!strict`
- suppressing analyzer errors instead of fixing the contract source
- large orchestrator/prompt-policy redesigns unrelated to builder/gate work

## Notes

- The intent is to lock in the quality gains from Phase 32+, not to start another open-ended cleanup campaign.
- Prefer a small number of boring, explicit helpers over a generic builder framework.
