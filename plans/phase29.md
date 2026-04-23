# Phase 29 — Hygiene Ratchet: Full `src/common` Coverage

## Summary

Expand the Phase 28 hygiene baseline from a tiny curated subset to full `src/common/*.luau` coverage for formatting and linting, while keeping type-checking conservative and deterministic.

## Why this boundary

- `src/common` is shared by most subsystems and is the highest-leverage low-risk hygiene surface.
- Full `src/agent` / `src/integrity` expansion currently introduces high-noise analyzer failures due to cross-module type export resolution in this setup.
- `src/common/Types.luau` still hits analyzer environment gaps for Roblox nominal types (`CFrame`, `Vector3`, etc.), so typecheck remains scoped away from that one file for now.

## Implementation Changes

### 1) Makefile hygiene scope ratchet

- Expand hygiene file scope to all `src/common/*.luau` for:
  - `make fmt`
  - `make fmt-check`
  - `make lint`
- Expand `make typecheck` to all common files **except** `src/common/Types.luau`.

### 2) Formatting rollout

- Apply StyLua formatting to newly in-scope files (notably `src/common/Constants.luau`) so `fmt-check` is clean.

### 3) Docs and contract updates

- Update `docs/code-hygiene.md` to reflect Phase 29 scope and explicit typecheck exception.
- Update `README.md` if scope wording still implies the older tiny subset.
- Update `plans/agent-handoff.md` with Phase 29 completion status and current-state notes.

## Validation

- `rokit install`
- `make fmt-check`
- `make typecheck`
- `make lint`
- `make hygiene`
- `make test-contracts`
- `make boot_smoke`
- `make refactor_fast`
- `make test TEST=phase14_integration`

## Non-goals

- No broad repo-wide migration.
- No bulk `--!strict` conversion.
- No expansion into `src/agent`, `src/integrity`, or runtime-heavy folders in this phase.
