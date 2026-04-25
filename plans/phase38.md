# Phase 38 — Bridge Diagnostics Sidequest

## Status

Complete.

## Goal

Make `AutoTrackTestBridge` diagnosable when it is installed but disabled, and reduce confusion between normal bridge suites and live-session trace export.

This is a tooling sidequest only. It should not change gameplay, simulation behavior, Rojo mappings, or test-suite semantics beyond clearer bridge diagnostics.

## Key Changes

- Replace the toolbar's silent enable/disable-only behavior with a small `DockWidgetPluginGui` status panel.
- Keep the UI narrow and operational: show bridge enabled state, poll URL, last poll time/result, last error, busy/current command, and edit/play context.
- Add a `Bridge Enabled` toggle in that panel and keep the toolbar button state synchronized.
- Add a `Copy Diagnostics` action with plugin version, enabled state, base URL, last poll state/error, busy state, and current command id/suite when present.
- Change the bridge protocol so the plugin still heartbeats to `/poll` while disabled, including `enabled=false` and `busy=false`.
- Update the CLI so an installed-but-disabled plugin fails fast with a specific message instead of timing out as if the plugin were missing.
- Clarify the `llm_trace_export` path in CLI output: it is a live-session export command and requires an active Play session with an existing trace.

## Acceptance Criteria

- `make boot_smoke` reports a clear installed-but-disabled error when the plugin is disabled.
- The plugin status panel makes the persisted `bridge_enabled` state visible after Studio restart.
- A disabled plugin does not execute queued commands, but the CLI can still detect that it is installed.
- Normal enabled bridge suites still pass through the maintained `make` workflow.
- Live trace export errors distinguish "bridge unavailable" from "no active Play session".

## Verification

- Disable the bridge from the plugin panel, run `make boot_smoke`, and confirm the CLI reports the disabled state directly.
- Re-enable the bridge, run `make boot_smoke`, and confirm the suite passes.
- Run `make export-llm-trace` outside Play and confirm the error names the live-session precondition.
- Run `make test-contracts`, `make fmt-check`, `make typecheck`, and `make lint`.

## Final implementation notes

- The toolbar button opens the diagnostics panel; enable/disable is owned by the panel toggle.
- `Copy Diagnostics` populates and selects a read-only diagnostics text box instead of requiring OS clipboard access.
- `/poll` carries enabled/busy/context metadata; disabled plugins heartbeat but never claim commands.
- `llm_trace_export` is sent as a live-session export command by the CLI, matching the existing Studio-side behavior.
- The diagnostics UI was manually verified working in Studio, and `make install-test-bridge-plugin` copies the bridge script to the WSL-translated Roblox plugin folder before Studio restart.
