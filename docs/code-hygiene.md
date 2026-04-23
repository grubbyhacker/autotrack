# Code Hygiene Milestone (Phase 1)

## Goal

Add a small deterministic Luau hygiene gate that agents can run the same way locally and in CI, without forcing a broad style/type migration.

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
make lint
make hygiene
```

`make hygiene` runs:

1. `fmt-check`
2. `typecheck`
3. `lint`

No interactive prompts are used.

## Current Scope Boundary

To avoid a giant migration, hygiene currently targets `src/common/*.luau`.

In-scope examples:

- `src/common/Constants.luau`
- `src/common/LLMConfig.luau`
- `src/common/LaunchOutlier.luau`
- `src/common/LevelMappings.luau`
- `src/common/PadValueUtils.luau`
- `src/common/RuntimeTuning.luau`
- `src/common/Types.luau`

Typecheck boundary:

- `make typecheck` currently excludes `src/common/Types.luau`.
- Reason: under the current deterministic CLI analyzer setup, Roblox nominal type names in this schema module still produce environment-resolution noise.

Formatting is non-negotiable inside this scoped set.

## Strict Mode Boundary

No bulk `--!strict` migration in this milestone.

Reason:

- Most modules currently depend on dynamic Roblox DataModel access patterns and would need broader type contract work.
- Keeping strictness unchanged avoids high-noise failures and protects agent iteration speed.

Future ratchet:

- Expand hygiene file scope in small batches.
- Convert leaf modules to `--!strict` only when they can be made green with small safe edits.
