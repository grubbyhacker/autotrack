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
- Typecheck runs with a tiny pinned Luau globals definitions file: `tools/luau/globals.d.luau`.

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
2. `typecheck`
3. `lint`

No interactive prompts are used.

## Current Scope Boundary

Formatting and linting now target repo-tracked Luau source under `src/` plus repo-tracked Luau source under `studio/`.

Repo-wide source hygiene intentionally excludes analyzer definition inputs such as `tools/luau/globals.d.luau`.

Examples now in scope for `fmt` / `fmt-check` / `lint`:

- `src/common/Constants.luau`
- `src/orchestrator/JobRunner.luau`
- `src/ui/HUDRegistry.luau`
- `src/verifier/VerifierController.luau`

Typecheck boundary:

- `make typecheck` remains a documented green subset target.
- `make typecheck-report` runs the analyzer across repo-wide tracked source without failing the overall hygiene contract.
- Reason: under the current deterministic CLI analyzer setup, full-repo analysis still hits Roblox environment-resolution gaps (`Vector3`, `CFrame`, `Enum`, `DateTime`, etc.) and exported-type resolution gaps (`Types.*`) that are larger than a formatting/lint ratchet.

Formatting is non-negotiable across the repo-wide source hygiene set.

## Strict Mode Boundary

No bulk `--!strict` migration in this milestone.

Reason:

- Most modules currently depend on dynamic Roblox DataModel access patterns and would need broader type contract work.
- Keeping strictness unchanged avoids high-noise failures and protects agent iteration speed.

Future ratchet:

- Expand the green `make typecheck` subset in small, explicit batches.
- Convert leaf modules to `--!strict` only when they can be made green with small safe edits.
- Treat analyzer-environment fixes and exported-type cleanup as their own tracked work rather than hiding them behind disabled checks.
