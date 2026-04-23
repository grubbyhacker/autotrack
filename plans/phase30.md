# Phase 30 — Repo-Wide Luau Hygiene Ratchet

## Summary

Use Phase 30 to complete repo-wide formatting and linting for repo-tracked Luau source under `src/` plus any repo-tracked Studio Luau sources, while keeping typechecking on a documented green subset and adding a non-gating full-repo analyzer report target.

## Why this shape

- Repo-wide `fmt-check` is realistic but broad; the current repo-wide probe shows about 75 files need formatting.
- Repo-wide `lint` is realistic; the current issue mix is mostly cleanup-level warnings (`multiple_statements`, `unused_variable`, `manual_table_clone`, and Roblox UI construction style warnings).
- Repo-wide `typecheck` is not yet a pure cleanup task under the current CLI analyzer setup. The main blockers are analyzer environment gaps for Roblox globals/types and exported-type resolution gaps across modules.
- `tools/luau/globals.d.luau` is a tool input for `luau-lsp analyze`, not repo source code, and should not be treated as a normal repo-wide formatting/lint target.

## Implementation Changes

### 1) Repo-wide source hygiene scope

- Redefine repo-wide source hygiene scope as:
  - all `src/**/*.luau`
  - all `src/**/*.server.luau`
  - all `src/**/*.client.luau`
  - all repo-tracked Studio Luau sources under `studio/`
- Exclude `tools/luau/globals.d.luau` from repo-wide `fmt` / `fmt-check` / `lint`.
- Keep broad rule disables out of `selene.toml`; prefer code cleanup over config suppression.

### 2) Makefile command contract

- Keep existing targets:
  - `make fmt`
  - `make fmt-check`
  - `make typecheck`
  - `make lint`
  - `make hygiene`
- Change scope so `fmt`, `fmt-check`, and `lint` run against the repo-wide source scope above.
- Keep `make typecheck` deterministic and green on its documented subset for this phase.
- Add `make typecheck-report` as a non-gating full-repo analyzer discovery target.
- Keep `make hygiene` as `fmt-check + typecheck + lint` so the existing command contract remains stable, with docs stating that `typecheck` is still subset-scoped in Phase 30.

### 3) Phase 30 verification seam

- Add `src/orchestrator/TestPhase30.luau` with a minimal suite that proves the Phase 30 contract is wired:
  - `make test TEST=phase30` / `/test phase30` dispatch path exists
  - suite emits structured pass/fail lines through the standard test runner path
- Wire the suite into:
  - `src/orchestrator/TestDispatcher.luau`
  - `tools/test_bridge_config.json`
  - `Makefile` if a direct target exists for other phases

### 4) Cleanup order and batching

Apply repo-wide hygiene in this order, validating after each batch:

1. `src/common` baseline confirmation
2. `src/mechanics` + `src/integrity`
3. `src/track` + `src/verifier`
4. `src/ui` + `src/client`
5. `src/agent`
6. `src/orchestrator` test/support modules
7. `src/orchestrator` runtime modules

Rules during cleanup:

- formatting first, lint cleanup second
- prefer syntax-only rewrites
- treat orchestrator runtime files as the highest-risk batch and finish them last
- if a file needs a nontrivial semantic rewrite to satisfy lint, stop and split that file into a smaller follow-up instead of folding risky logic changes into this phase

## Test / Verification

Static gates after each batch:

- `make fmt-check`
- `make lint`
- `make test-contracts`

Minimum runtime checks after each batch:

- `make boot_smoke`
- `make refactor_fast`

Batch-specific checks:

- `src/mechanics` / `src/integrity`
  - `make mechanics_regression`
  - `make test TEST=phase24`
  - `make test TEST=phase27`
- `src/track` / `src/verifier`
  - `make mechanics_regression`
  - `make test TEST=phase21`
  - `make test TEST=phase27`
- `src/ui` / `src/client`
  - `make test TEST=phase14_integration`
  - `make test TEST=phase21`
- `src/agent`
  - `make test TEST=phase14_integration`
  - `make test TEST=phase24`
  - `make test TEST=llm_trace_export`
- `src/orchestrator` test/support
  - `make test TEST=phase21_unit`
  - `make test TEST=phase24`
  - `make test TEST=phase27`
- `src/orchestrator` runtime
  - full maintained verification snapshot from `plans/agent-handoff.md`

Phase completion gate:

- repo-wide `make fmt-check` is green for tracked source Luau
- repo-wide `make lint` is green for tracked source Luau
- `make hygiene` is green under the documented Phase 30 contract
- `make typecheck` is green on its documented subset
- `make typecheck-report` exists and reports the remaining full-repo analyzer backlog
- `make test TEST=phase30` passes
- maintained runtime validation passes after the final orchestrator batch

## Non-goals

- No bulk `--!strict` migration
- No broad analyzer-environment redesign beyond what is required to preserve deterministic subset typechecking and report full-repo failures
- No large behavior changes disguised as hygiene cleanup

## Notes

- The user explicitly requested an iterative, risk-led rollout, so repo-wide formatting/linting should be landed with frequent validation rather than as one blind bulk edit.
- The existing command contract should remain non-interactive and `make`-driven.
