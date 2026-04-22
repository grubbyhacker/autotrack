# Phase 20 — Endurance Agent Memory

## Summary

Phase 20 adds bounded, session-local endurance memory so the orchestrator,
proposer, and repair agent can carry forward short interpreted lessons during a
single live run.

This phase keeps the current structured histories from earlier phases and adds
two new memory surfaces on top:

1. shared run memory curated by the orchestrator
2. role-local notebooks for orchestrator, proposal, and repair

Memory remains:

- ephemeral
- append-only
- bounded by fixed ring buffers
- visible in a compact HUD form
- subordinate to current telemetry and legality checks

## Public Interface / Type Changes

- Add `MemoryEntry` and `RunMemory` contracts to `src/common/Types.luau`.
- Extend `OrchestratorContext` with `memory: RunMemory`.
- Extend endurance `Request` and `FailurePacket` with `memory_context: RunMemory?`.
- Extend `AttemptRecord` with optional `memory_note`.
- Extend `OrchestratorDecision` with optional `memory_note`.
- Extend `CIJob` with optional `proposal_memory_note`.

Chosen defaults:

- all roles may append role-local notes
- only the orchestrator may promote to shared memory
- notes are optional and returned inline from existing LLM calls
- role-local notes must stay in the role-owned scope
- shared memory is curated server-side after a completed job outcome

## Implementation Changes

- Add an `EnduranceMemory` helper in `src/orchestrator/` to own:
  - empty-memory construction
  - cloning
  - bounded append behavior
  - exact-duplicate shared-note suppression
  - compact HUD note extraction
- Update `LLMAdapter`, `PromptBuilder`, `OrchestratorPromptBuilder`, and
  `OpenRouterProvider` so `orchestrate`, `propose`, and `repair` can receive the
  relevant memory slices and optionally return validated `memory_note` objects.
- Update `OrchestratorAgent` to own endurance-session memory, append
  orchestrator/proposal/repair notes, and promote at most one shared lesson per
  completed job.
- Update `JobRunner` to thread `memory_context` through endurance requests,
  proposal, and repair, while leaving player requests unchanged.
- Extend `UIState` and the HUD client/UI modules with a compact memory surface:
  - shared depth
  - proposal depth
  - repair depth
  - latest shared/proposal/repair notes
- Surface malformed structured agent responses in the existing HUD warning strip
  so live operators can distinguish bad payloads from transport/backend errors.

## Test Plan

- Add `src/orchestrator/TestPhase20.luau`.
- Wire `phase20` into:
  - `src/orchestrator/TestDispatcher.luau`
  - `tools/test_bridge_config.json`
  - `Makefile`
- Add assertions for:
  - prompt memory inclusion by role
  - note validation and normalization of wrong scopes
  - request / failure-packet memory threading
  - bounded local memory append behavior
  - shared-memory promotion and duplicate suppression
  - trace export carrying memory context and notes
  - HUD memory default attributes
  - HUD warning text for malformed agent responses

## Verification

- `make test TEST=phase20`
- `make test TEST=phase19`
- `make test TEST=phase14_5`
- `make test TEST=phase14_integration`
- `make endurance-trace MODEL=google/gemma-3-4b-it DURATION=60 OUT=traces/phase20-live-gemma-fixed.json`
- `make endurance-trace MODEL=qwen/qwen-turbo DURATION=60 OUT=traces/phase20-live-qwen-ui-warning.json`

## Assumptions

- Phase 20 memory is endurance-only in v1.
- No cross-session persistence is introduced.
- No separate memory-compaction LLM call is introduced.
- Shared memory remains small and curated to preserve prompt clarity.
