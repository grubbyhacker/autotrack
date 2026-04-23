# Phase 28 — Luau Hygiene Baseline (Scoped, Deterministic)

## Summary

Introduce a minimal, deterministic Luau hygiene toolchain that agents can run locally and in CI using the same `make` commands, without forcing a disruptive whole-repo migration.

## Implementation Changes

### 1) Toolchain manager and pinned tools

- Keep `rokit` as the single toolchain manager.
- Pin hygiene tools in `rokit.toml`:
  - `stylua`
  - `selene`
  - `luau-lsp`

### 2) Hygiene commands in Makefile

- Add explicit non-interactive targets:
  - `make fmt`
  - `make fmt-check`
  - `make typecheck`
  - `make lint`
  - `make hygiene`
- `make hygiene` runs `fmt-check` + `typecheck` + `lint` only (fast static gate).
- Ensure tool invocations resolve to Rokit-managed binaries.

### 3) Config-first setup

- Add `.stylua.toml`.
- Add `selene.toml` (`std = "roblox"`).
- Add `.luaurc` with conservative global declarations.
- Add `tools/luau/globals.d.luau` for deterministic scoped `luau-lsp analyze` runs.

### 4) Scoped rollout boundary

- Intentionally scope phase-1 hygiene to a curated file set in `src/common/`:
  - `LLMConfig.luau`
  - `LaunchOutlier.luau`
  - `LevelMappings.luau`
  - `PadValueUtils.luau`
  - `RuntimeTuning.luau`
- Apply formatter only within this scoped set for now.

### 5) Contract/doc updates

- Add `docs/code-hygiene.md` as the milestone design/contract note.
- Update `README.md` with hygiene commands and scope.
- Update `AGENTS.md` with hygiene command contract and boundaries.
- Keep existing suite contract tooling healthy by excluding hygiene targets from suite-name validation in `tools/check_test_contract.py`.

## Strictness boundary

- Do not perform bulk `--!strict` migration in this phase.
- Ratchet strictness later on leaf modules with explicit scoped follow-up.

## Test / Verification

- `rokit install`
- `make fmt-check`
- `make typecheck`
- `make lint`
- `make hygiene`
- `make test-contracts`

## Notes

- Phase 1 hygiene is intentionally narrow to avoid high-noise diffs and preserve agent iteration speed.
- Expansion to broader directories should be done in small ratchet phases.
