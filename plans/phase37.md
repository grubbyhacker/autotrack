# Phase 37 — Strictness Ratchet and JSON Contracts

## Status

Complete.

Final implementation notes:

- Strict coverage increased to `13 / 106` Luau files after adding the Phase 37 suite.
- `Types.JsonValue`, `Types.JsonArray`, and `Types.JsonObject` now cover trace payloads, trace run meta/summary, trace export tables, and sector serializer output.
- The obvious broad `any` type annotations were removed; remaining `any` search hits are plain English comments/strings.
- `make test TEST=llm_trace_export` was attempted after sequential bridge suites, but the bridge reported `no active Play session for LLM trace export`. This command is a live-session export path and needs an active traced Play session.

## Goal

Raise Luau `--!strict` coverage with a bounded cleanup of the remaining broad type surfaces left after Phase 36.

This phase is a type-safety and contract-cleanup phase only. It must not retune mechanics, change prompt policy, or alter gameplay behavior.

## Deliverables

### 1. Add Shared JSON Contracts

Add shared JSON-safe types in `src/common/Types.luau`:

- `JsonPrimitive`
- `JsonValue`
- `JsonArray`
- `JsonObject`

Use these for trace journal payloads, trace export tables, sector serializer output, and export/test snapshot code that currently uses `{ [string]: any }`.

### 2. Remove Known Broad `any` Surfaces

Replace the obvious remaining broad `any` annotations around:

- `LLMTraceJournal` payload/meta/summary/export tables
- `SectorSerializer.toTable`
- test snapshot/export helpers
- `JobRunner` challenge-up return tuple
- validator diagnostic access

Intentional malformed-test payloads may remain malformed, but their types should be narrow and explicit rather than hidden behind broad `any`.

### 3. Continue Builder Migration

Use `ContractBuilders.setNumericLever` and `ContractBuilders.setPad` for valid `AgentAction` construction in:

- `MinimalProposer`
- LLM-oriented tests that repeat raw valid repair-action tables
- Phase 24 verification-profile tests

Negative tests may keep raw JSON-like tables when the raw shape is the behavior under test.

### 4. Tighten Test Factories

Make `src/orchestrator/TestFactories.luau` strict by replacing untyped override bags with typed fixture option shapes.

Factory defaults should remain behavior-compatible with Phase 36 tests while allowing tests to override complete typed slices.

### 5. Medium Strictness Ratchet

Raise strict-file coverage from the current `4 / 105` to at least `12 / 105`.

Primary promotion candidates:

- `src/agent/LLMTraceJournal.luau`
- `src/track/SectorSerializer.luau`
- `src/orchestrator/TestFactories.luau`
- `src/orchestrator/TestPhase36.luau`
- `src/orchestrator/TestPhase26.luau`
- `src/orchestrator/TestPhase24.luau`
- `src/orchestrator/TestPhase17.luau`
- `src/agent/ActionValidator.luau`

Fallback candidates if a primary file requires non-local redesign:

- `src/orchestrator/TestPhase13.luau`
- `src/orchestrator/TestPhase19.luau`
- `src/orchestrator/TestPhase20.luau`
- `src/orchestrator/TestPhase14_5.luau`

## Phase Test

Add `src/orchestrator/TestPhase37.luau` and wire `phase37` through:

- `src/orchestrator/TestDispatcher.luau`
- `tools/test_bridge_config.json`
- `Makefile`

The suite should assert:

- JSON contracts can represent trace payload/meta/summary/export data.
- `LLMTraceJournal` still sanitizes Roblox values and cycles into JSON-safe output.
- `SectorSerializer.toTable` preserves the existing serialized sector shape.
- `TestFactories` produce complete default strict fixtures and typed overrides.
- `ContractBuilders` action builders produce valid action fixtures.

## Acceptance Criteria

- At least eight more Luau files are promoted to `--!strict`.
- `rg -n '\bany\b|\{ \[string\]: any \}|\[string\]: any' src studio -g '*.luau'` shows no broad production JSON/serializer/test snapshot type surfaces.
- Existing trace export and sector serializer wire shapes remain unchanged.
- Builder/factory cleanup does not weaken shared production types.
- The maintained typecheck and hygiene gates stay green.

## Verification

Completed:

- `make fmt-check`
- `make typecheck`
- `make lint`
- `make phase37`
- `make phase24`
- `make phase26`
- `make phase36`
- `make hygiene`

Attempted:

- `make test TEST=llm_trace_export` — bridge returned `no active Play session for LLM trace export`.
