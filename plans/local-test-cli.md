# Local CLI Test Runner

## Summary

Add a local terminal-driven harness so AutoTrack suites can be run as:

```sh
make phase6_integration
make phase7_unit
make test TEST=phase6_integration
```

without Claude/MCP.

The bridge direction is:

1. `make` starts a one-shot localhost server
2. a Studio plugin polls that server
3. the plugin starts/stops simulation, waits for the correct boot mode, and fires `AutoTrack_TestCmd`
4. the game publishes structured suite status in addition to console lines
5. the plugin posts results back to the one-shot server

This keeps the existing runtime tests intact while making them usable from the terminal.

## Key Changes

- Add `src/orchestrator/TestSession.luau` as the structured suite-status recorder.
- Update `TestUtils.luau` and `TestRunner.server.luau` so all existing suites publish pass/fail/error lines and final status into `ReplicatedStorage.AutoTrackTestStatus`.
- Add checked-in bridge config for suite classification and timeouts.
- Add a Python CLI bridge that can:
  - serve one queued command on localhost
  - wait for the Studio plugin to pick it up
  - print concise terminal progress
  - exit nonzero on failures or timeouts
- Add a root `Makefile` with direct suite targets and generic `make test TEST=<suite>`.
- Add a Studio plugin source file that:
  - polls the localhost bridge
  - stops any running simulation
  - sets `AutoTrack_SkipBootBaseline`
  - starts simulation
  - waits for `TestRunner` and baseline readiness when needed
  - fires the requested suite
  - reads `AutoTrackTestStatus`
  - posts results back to localhost
- Add setup and usage docs, including plugin-install expectations and the HTTP permission requirement.

## Interfaces

### Terminal

- `make phase1` through `make phase7_integration`
- `make test TEST=<suite>`
- `make test-list`

### Localhost bridge

- `GET /health`
- `GET /poll`
- `POST /result`

`/poll` returns either idle status or one command:

```json
{
  "ok": true,
  "command": {
    "id": "phase6_integration-12345",
    "suite": "phase6_integration",
    "boot_mode": "baseline",
    "timeouts": {
      "runner_ready_seconds": 20,
      "baseline_ready_seconds": 60,
      "suite_seconds": 180
    }
  }
}
```

`/result` accepts:

```json
{
  "id": "phase6_integration-12345",
  "status": "passed",
  "suite": "phase6_integration",
  "boot_mode": "baseline",
  "pass_count": 3,
  "fail_count": 0,
  "error_count": 0,
  "lines": ["[TEST PASS: ...]"],
  "message": null
}
```

### In-game recorder

- `beginSuite(name)`
- `appendLine(text)`
- `finishSuite(status, message?)`
- `snapshot()`

Stored under `ReplicatedStorage.AutoTrackTestStatus` so plugins can read it in Studio.

## Test Cases

- `make test-list` prints every supported suite.
- `make phase7_unit` selects skip-baseline mode automatically and exits `0` on success.
- `make phase6_integration` selects baseline mode automatically and exits `0` on success.
- Unknown suite names fail before the bridge starts.
- If the Studio plugin is not running, the CLI exits with a direct setup error after timeout.
- If a suite emits `[TEST FAIL: ...]`, the CLI exits `1` and prints failing lines.
- Existing MCP/manual trigger behavior still works because `AutoTrack_TestCmd` and console prints remain unchanged.

## Assumptions

- Roblox Studio is already open on the synced place.
- The user installs/enables the checked-in plugin source once.
- The plugin is allowed to make localhost HTTP requests.
- `RunService:Run()` and `RunService:Stop()` remain available to plugins, and we accept their current semantics for local test sessions.
