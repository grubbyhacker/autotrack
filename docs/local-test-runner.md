# Local Test Runner

AutoTrack now supports terminal-triggered Studio test runs through:

```sh
make phase6_integration
make phase21_unit
make refactor_fast
make test TEST=phase6_integration
make test-list
```

## What this does

`make` starts a small localhost bridge. A Studio plugin polls that bridge, starts a Play session through `StudioTestService`, and the game returns a structured suite result back to the bridge.

This removes the Claude/MCP requirement for normal suite execution.

## One-time setup

1. Open Roblox Studio on the AutoTrack place with Rojo syncing this repo.
2. Install a local Studio plugin whose source is [`studio/AutoTrackTestBridge.server.lua`](../studio/AutoTrackTestBridge.server.lua).
3. Enable the plugin and allow it to access `127.0.0.1` / `localhost` when Studio prompts for HTTP permission.
4. Leave the plugin enabled while running `make` commands.

The plugin defaults to polling `http://127.0.0.1:8765`.

## Running suites

List supported suites:

```sh
make test-list
```

Run a single suite:

```sh
make phase6_integration
```

or:

```sh
make test TEST=phase6_integration
```

Fast non-Studio contract check:

```sh
make test-contracts
```

Fast one-boot refactor gate:

```sh
make refactor_fast
```

Mechanic-focused regression gate:

```sh
make mechanics_regression
```

## Boot mode behavior

- Skip-baseline suites automatically set `AutoTrack_SkipBootBaseline = true`
- Baseline suites automatically set `AutoTrack_SkipBootBaseline = false`

The mapping lives in [`tools/test_bridge_config.json`](../tools/test_bridge_config.json).

## Exit codes

- `0` suite passed
- `1` suite failed
- `2` harness/config/runtime error
- `3` Studio bridge unavailable or timed out

## Current limitations

- Studio must already be open on the synced place.
- The plugin source is checked in, but plugin packaging/install is still manual.
- The localhost bridge runs one suite per command and is not a long-lived daemon.
- Bridge-backed commands are serialized by a CLI queue lock (`tools/.autotrack_bridge.lock`). If two commands start at once, the later one waits instead of failing with a port-in-use race.
- Lock timeout defaults to 1800 seconds; override with `AUTOTRACK_BRIDGE_LOCK_TIMEOUT_SECONDS` (`0` = wait forever).

## Bridge diagnostics

- The plugin now logs bridge polling failures to Studio Output with the prefix `[AutoTrackTestBridge]`.
- If `make ...` reports `Studio bridge did not connect`, check Studio Output first for HTTP/permission errors.
- After Studio upgrades, re-allow localhost HTTP access prompts if they reappear.
