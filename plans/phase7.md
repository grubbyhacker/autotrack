# Phase 7 — LLM Adapter (Narrow Boundary, Swappable Backend)

## Context

Phase 6 proved the end-to-end CI loop using a deterministic no-LLM backend (`MinimalProposer`). Phase 7 should not destabilize that loop. The goal here is to build the **agent boundary** so the orchestrator talks only to `LLMAdapter`, while the actual backend remains swappable between:

- a proven mock backend (`MinimalProposer`)
- future Claude/Codex backends
- test stub backends

This phase is about **interface discipline and validation**, not about network transport.

---

## Deliverable

The orchestrator uses `LLMAdapter.propose(...)` and `LLMAdapter.repair(...)` exclusively. The adapter:

- builds structured prompts via `PromptBuilder`
- delegates to a configurable backend
- parses structured responses
- validates them with `ActionValidator`
- rejects mismatched or malformed output

Default backend remains a deterministic mock so Phase 6 behavior stays live and testable.

---

## Files to change

### `src/agent/PromptBuilder.luau`

Implement:

- `systemPrompt()`
- `initialProposal(request)`
- `repairStep(packet)`

Requirements:

- compact but explicit
- include supported mechanics, pad values, and repair rule that only one action is allowed
- include defaults for the initial proposal
- include current sector state, hints, and legal actions for repair
- instruct backend to return JSON only

### `src/agent/LLMAdapter.luau`

Implement the swappable adapter boundary.

Public API:

- `propose(request): (SectorState?, string?)`
- `repair(packet): (AgentAction?, string?, string?)`
- `setProvider(name, provider)`
- `useMockProvider()`
- `getProviderName()`
- `getLastExchange()`

Backend contract:

- `provider.propose(payload)` returns either a JSON string or table
- `provider.repair(payload)` returns either a JSON string or table

Default mock provider:

- wraps `src/orchestrator/MinimalProposer.luau`
- returns JSON-shaped results through the same parse/validate path as any future real backend

Validation rules:

- initial proposal must match requested `sector_id`
- initial proposal must match requested `mechanic`
- initial proposal must satisfy `ActionValidator.validateSectorState`
- repair response must contain exactly one action + a short explanation
- repair action must satisfy `ActionValidator.validateAction(action, packet.sector_state.mechanic)`

### `src/agent/ActionValidator.luau`

Tighten `validateSectorState(...)` enough for adapter use:

- supported mechanic required
- all legal numeric levers for the mechanic must be present and numeric
- pads must be valid enum values
- version must be numeric

### `src/orchestrator/JobRunner.luau`

Swap Phase 6’s direct `MinimalProposer` calls to `LLMAdapter`.

Behavior should remain identical under the mock backend.

### `src/orchestrator/TestPhase7.luau`

Add Phase 7 tests:

- prompt builder includes request/diagnostic context
- adapter mock backend returns valid initial proposal
- adapter mock backend returns valid repair action
- adapter rejects invalid sector mismatch
- adapter rejects invalid mechanic mismatch
- adapter rejects invalid repair action
- adapter rejects empty or overlong explanation
- adapter accepts custom injected provider

Integration test:

- inject a stub backend
- run one real `JobRunner.submit(...)`
- verify sector commit occurred and the stub provider’s `propose` path was used
- restore mock backend afterward

### `src/orchestrator/TestRunner.server.luau`

Add:

- `phase7`
- `phase7_unit`
- `phase7_integration`

### `plans/agent-handoff.md`

After completion:

- mark Phase 7 complete
- record lessons learned about keeping the mock backend and validating adapter outputs strictly

---

## Verification

1. Skip-baseline session:
   - run `phase7_unit`
2. Baseline-enabled session:
   - run `phase7_integration`
3. Confirm Phase 6 behavior still works through the adapter-backed path

---

## Notes

- Do not add real network calls yet.
- Do not let the orchestrator depend on provider-specific response shapes.
- Keep `MinimalProposer` as the default mock backend until a real transport exists.
