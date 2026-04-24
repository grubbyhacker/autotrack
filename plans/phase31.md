# Phase 31 — Roblox-Aware Luau Typecheck Foundation

## Summary

Make `luau-lsp analyze` understand Roblox globals/types and Rojo-based module resolution well enough to expand `make typecheck` beyond the current minimal green subset. This phase is infrastructure-first: fix the analyzer environment and require resolution before treating repo-wide type failures as meaningful code problems.

## Why this phase is needed

- Phase 30 completed repo-wide `fmt` / `fmt-check` / `lint`, but full-repo `typecheck-report` still fails primarily for analyzer-environment reasons rather than hygiene reasons.
- Current `make typecheck` runs `luau-lsp analyze --platform=standard` with a tiny custom definitions file (`tools/luau/globals.d.luau`) that only declares:
  - `game`
  - `workspace`
  - `script`
  - `task`
- That environment does not resolve Roblox globals/types used throughout the repo:
  - `Vector3`
  - `CFrame`
  - `Enum`
  - `DateTime`
  - `Color3`
  - `Camera`
  - `BasePart`
  - `Folder`
- The shared schema module `src/common/Types.luau` depends on Roblox nominal types and currently fails under this analyzer contract.
- Many downstream modules also fail on exported type aliases such as `Types.Request`, `Types.SectorState`, and `Types.AgentAction`, which makes the full-repo report noisy and blocks useful ratcheting.
- The repo uses Rojo/DataModel-style require paths; analyzer results will remain poor until `luau-lsp analyze` is given a Rojo sourcemap or equivalent configuration so those requires resolve back to local source files.

## Implementation Changes

### 1) Replace the minimal analyzer environment with a Roblox-aware contract

- Update the checked-in typecheck workflow so `luau-lsp analyze` runs in a Roblox-aware configuration instead of relying on `--platform=standard` plus four hand-written globals.
- Supply Roblox engine API types through a vendored pinned third-party definitions file (`globalTypes.None.d.luau`) checked into `tools/luau/`.
- Keep custom definition files only for true project-specific globals if any remain necessary after the Roblox-aware setup is in place.
- Do not hand-write a broad Roblox declarations layer in-repo unless a very small targeted shim is required for a proven gap.

### 2) Add sourcemap-backed analysis for Rojo require resolution

- Generate a Rojo-style sourcemap from `default.project.json` as part of the typecheck workflow.
- Feed that sourcemap into `luau-lsp analyze` so DataModel-style require chains resolve back to repo files.
- Keep the workflow deterministic and non-interactive; the sourcemap generation path must be `make`-driven.
- If a checked-in generated sourcemap is not acceptable, generate it into an ignored local file during the command.

### 3) Prove the foundation on a targeted pilot set

Pilot files:

- `src/common/Types.luau`
- `src/agent/ActionValidator.luau`
- `src/client/TrackCamera.client.luau`

These three files cover the key blocking classes:

- Roblox nominal types in exported schemas
- downstream `Types.*` alias usage
- client-side Roblox globals / engine classes

Pilot success criteria:

- `Types.luau` no longer errors on `CFrame`, `Vector3`, or `Folder`
- `ActionValidator.luau` no longer errors on `Types.AgentAction`, `Types.SectorState`, or `Types.Mechanic`
- `TrackCamera.client.luau` no longer errors on `Camera`, `BasePart`, `Vector3`, `CFrame`, or `Enum`

### 4) Separate residual failures by category

After the pilot is green, classify remaining full-repo `typecheck-report` failures into explicit buckets:

- Roblox environment/config gaps
- Rojo/sourcemap resolution gaps
- genuine code/type issues
- optional strictness improvements

Do not mix infrastructure failures and code cleanup in the same milestone without labeling them clearly.

### 5) Expand the green `make typecheck` subset in safe batches

Expand the gated subset only after the pilot foundation works:

1. `src/common` including `Types.luau`
2. low-noise `src/agent` modules
3. `src/integrity`
4. selected `src/client` / `src/ui`
5. later phases: `src/track`, `src/verifier`, `src/orchestrator`

Rules:

- No bulk `--!strict`
- No broad disables to suppress analyzer noise
- Prefer fixing configuration first, then real code issues, then tightening strictness only where low-risk

### 6) Keep Phase 30 repo-wide reporting intact

- Preserve:
  - `make fmt`
  - `make fmt-check`
  - `make lint`
  - `make hygiene`
  - `make typecheck-report`
- Update:
  - `make typecheck` to use the new Roblox-aware foundation and expanded green subset
- Keep `make typecheck-report` as the non-gating full-repo visibility target until a later ratchet phase explicitly promotes more of that surface into the green gate.

## Test / Verification

Static workflow validation:

- `make fmt-check`
- `make lint`
- `make hygiene`
- `make test-contracts`

Typecheck foundation validation:

- `make typecheck`
- `make typecheck-report`

Pilot verification:

- direct analyzer confirmation for:
  - `src/common/Types.luau`
  - `src/agent/ActionValidator.luau`
  - `src/client/TrackCamera.client.luau`

Runtime regression validation:

- `make boot_smoke`
- `make refactor_fast`
- `make test TEST=phase21_unit`

If any typecheck-driven code edits touch runtime-heavy modules, also run:

- `make test TEST=phase14_integration`
- `make test TEST=phase24`
- `make test TEST=phase27`

## Acceptance Criteria

- `make typecheck` runs with a Roblox-aware analyzer contract
- Rojo/DataModel-style require resolution is available to the analyzer via sourcemap-backed analysis
- The 3-file pilot set is green
- `src/common/Types.luau` is included in the green subset
- `make typecheck-report` still works and shows a reduced backlog relative to Phase 30
- No broad suppressions or bulk strictness migration were introduced

## Assumptions and Defaults

- The main blocker is analyzer environment/resolution, not formatting/lint cleanliness.
- Roblox globals/types should be supplied by a vendored pinned `luau-lsp` definitions artifact plus Rojo sourcemap support, not by a large hand-maintained declarations file in this repo.
- Full-repo typechecking is still not a gate in this phase; the goal is to make a materially larger green subset trustworthy.
