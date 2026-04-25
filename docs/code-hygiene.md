# Code Hygiene Milestone

## Goal

Maintain a deterministic Luau hygiene gate that agents can run the same way locally and in CI, while ratcheting scope carefully and keeping risky type-system work explicit.

## Toolchain Manager

- Use `rokit` as the single pinned tool manager for this repo.
- Tool versions are pinned in `rokit.toml`.
- Install/update with:

```sh
rokit install
```

## Tool Choices

- Formatter: `StyLua`
- Type checker: `luau-lsp analyze` (Luau analyzer frontend)
- Linter: `Selene` (`std = "roblox"`)

Why this set:

- Native Luau-focused tools with stable CLIs.
- Fast and deterministic output.
- Easy pinning and reproducibility through existing `rokit` workflow.
- Typecheck runs with vendored Roblox definitions (`tools/luau/globalTypes.None.d.luau`) plus a generated Rojo sourcemap (`sourcemap.json`).

## Command Contract

Run through `make`:

```sh
make fmt
make fmt-check
make typecheck
make typecheck-report
make lint
make hygiene
```

`make hygiene` runs:

1. `fmt-check`
2. full-repo `typecheck`
3. `lint`

No interactive prompts are used.

## Current Scope Boundary

Formatting and linting now target repo-tracked Luau source under `src/` plus repo-tracked Luau source under `studio/`.

Repo-wide source hygiene intentionally excludes vendored analyzer inputs such as `tools/luau/globalTypes.None.d.luau`.

Examples now in scope for `fmt` / `fmt-check` / `lint`:

- `src/common/Constants.luau`
- `src/orchestrator/JobRunner.luau`
- `src/ui/HUDRegistry.luau`
- `src/verifier/VerifierController.luau`

Typecheck boundary:

- `make typecheck` is the authoritative full static-analysis gate for repo-tracked Luau source under `src/` and `studio/`.
- `make typecheck-report` is a compatibility alias that delegates to `make typecheck`; do not treat it as a separate non-gating backlog report.
- Standalone analysis remains Roblox-aware by generating `sourcemap.json` from `default.project.json` and passing the vendored Roblox definitions file to `luau-lsp analyze`.

Formatting is non-negotiable across the repo-wide source hygiene set.

## Strict Mode Boundary

No bulk `--!strict` migration.

Reason:

- Most modules currently depend on dynamic Roblox DataModel access patterns and would need broader type contract work.
- Keeping strictness unchanged avoids high-noise failures and protects agent iteration speed.

Future ratchet:

- Keep `make typecheck` full-repo green before and after any source change.
- Convert leaf modules to `--!strict` only when they can be made green with small safe edits.
- Treat analyzer-environment fixes and exported-type cleanup as their own tracked work rather than hiding them behind disabled checks.
