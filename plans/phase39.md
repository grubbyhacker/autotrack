# Phase 39 — Strict Typing Expansion by Risk/Return

## Status

Complete.

Final implementation notes:

- Strict coverage increased from `13 / 106` to `27 / 107` Luau files.
- The primary low-risk batch was promoted without removing any existing strict marker.
- `LevelMappings` now has explicit mechanic-shaped local record types so existing `.RampJump` / `.Chicane` / `.CrestDip` property reads remain analyzer-friendly.
- `TestPhase39` covers the newly promoted helper contracts and is wired through the maintained Makefile / bridge suite path.

## Goal

Expand `--!strict` coverage by promoting high-return, low-to-medium-risk Luau files first.

This phase continues the Phase 36/37 strictness ratchet. It must not remove strictness from existing files, weaken shared contracts, retune mechanics, alter LLM behavior, or change gameplay physics.

## Deliverables

### 1. Promote Low-Risk, High-Return Files

Primary promotion candidates:

- `src/common/RuntimeTuning.luau`
- `src/orchestrator/Tracer.luau`
- `src/orchestrator/JobLock.luau`
- `src/verifier/ReacquireDetector.luau`
- `src/track/SectorRollback.luau`
- `src/orchestrator/TestUtils.luau`
- `src/orchestrator/TestSuiteRunner.luau`
- `src/orchestrator/TestGates.luau`
- `src/common/LLMConfig.luau`
- `src/common/LevelMappings.luau`
- `src/track/SectorRegistry.luau`
- `src/track/CornerPath.luau`
- `src/mechanics/CrestDipPath.luau`

Use narrow local type aliases where needed, especially for config/map shapes.

### 2. Use Medium-Risk Fallbacks Only If Needed

If a primary candidate requires broad casts or non-local redesign, defer it and promote one of:

- `src/integrity/ChicaneIntegrity.luau`
- `src/integrity/CrestDipIntegrity.luau`
- `src/integrity/RampJumpIntegrity.luau`
- `src/mechanics/PadBuilder.luau`
- `src/mechanics/ChicanePath.luau`
- `src/mechanics/CrestDipBuilder.luau`
- `src/mechanics/RampJumpBuilder.luau`

### 3. Add Phase 39 Coverage

Add `src/orchestrator/TestPhase39.luau` and wire `phase39` through the maintained suite contract:

- `src/orchestrator/TestDispatcher.luau`
- `tools/test_bridge_config.json`
- `Makefile`

The suite should exercise strict-promoted helper behavior without relying on UI reads or hidden state.

## Acceptance Criteria

- Strict coverage increases from `13 / 106` to at least `25 / 106` files.
- No existing `--!strict` marker is removed.
- No broad `any` or fake strictness casts are introduced.
- Public runtime behavior and existing table/wire shapes remain unchanged.
- Maintained static and phase gates stay green.

## Verification

Completed:

- `make fmt-check`
- `make typecheck`
- `make lint`
- `make hygiene`
- `make phase39`
- `make refactor_fast`
