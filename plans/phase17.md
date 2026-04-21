# Phase 17 — Server-Side LLM Trace Journal

## Goal

Add server-owned LLM observability as an append-only in-memory journal at the LLM boundary. Capture orchestrator, proposal, and repair exchanges as ordered structured events, keep the full transcript server-side, and expose narrow retrieval paths for active Play sessions:

- `/test llm_trace_export`
- `python tools/autotrack_test_cli.py export-llm-trace`

No gameplay HUD transcript viewer, no persistence, and no duplicate instrumentation outside the canonical LLM boundary.

## Scope

1. Add explicit shared types for trace directions, roles, events, and runs in `src/common/Types.luau`.
2. Add `src/agent/LLMTraceJournal.luau` with:
   - `beginRun(meta)`
   - `append(eventLike)`
   - `finishRun(summary?)`
   - `getActiveRun()`
   - `getRecentRuns()`
   - `exportRun(runId?)`
   - `exportLatestRun()`
   - `clearForTests()`
   - bounded retention: 1 active + 3 recent completed runs
3. Instrument `src/agent/LLMAdapter.luau` only:
   - prompt events for `propose`, `repair`, `orchestrate`
   - response events for raw provider output and decoded output
   - error events for backend/decode/validation failures
   - include provider/model/kind metadata
4. Add run lifecycle ownership:
   - `JobRunner.submit` begins/finishes a run for normal non-endurance jobs
   - `OrchestratorAgent.run` begins/finishes one run spanning the whole endurance orchestration session
   - internal endurance submits reuse the active endurance run
5. Add export retrieval:
   - new targeted suite `llm_trace_export`
   - `TestSession` snapshot payload field for exported JSON-safe tables
   - `tools/autotrack_test_cli.py export-llm-trace`
   - narrow bridge command/result extension, not a generic RPC layer
6. Add/update maintained contract points:
   - `src/orchestrator/TestDispatcher.luau`
   - `src/orchestrator/StudioTestBootstrap.server.luau`
   - `src/orchestrator/TestSession.luau`
   - `tools/test_bridge_config.json`
   - `Makefile`
   - `studio/AutoTrackTestBridge.server.lua`

## Design Notes

- The journal owns sequence ordering per run. Callers never pass `seq`.
- Events remain append-only once recorded. Exports are JSON-safe tables only.
- `LLMAdapter.getLastExchange()` should keep working; it can map to the last traced exchange shape as long as existing tests still pass.
- The journal should tolerate missing active runs by auto-beginning a small fallback run when instrumentation fires outside an owned lifecycle.
- Endurance trace ownership must stay at the orchestration session level so orchestrator and downstream repair/proposal calls share one ordered run.
- Normal `/test` usage must stay narrow: summary in console lines, export data in snapshot payload.

## Files Expected To Change

- `plans/phase17.md`
- `plans/agent-handoff.md`
- `src/common/Types.luau`
- `src/agent/LLMTraceJournal.luau`
- `src/agent/LLMAdapter.luau`
- `src/orchestrator/JobRunner.luau`
- `src/orchestrator/OrchestratorAgent.luau`
- `src/orchestrator/TestPhase13.luau`
- `src/orchestrator/TestPhase17.luau`
- `src/orchestrator/TestDispatcher.luau`
- `src/orchestrator/TestSession.luau`
- `src/orchestrator/StudioTestBootstrap.server.luau`
- `tools/autotrack_test_cli.py`
- `tools/test_bridge_config.json`
- `Makefile`
- `studio/AutoTrackTestBridge.server.lua`

## Verification

Primary:

- `make test TEST=phase13_unit`
- `make test TEST=llm_trace_export`

Additional static/tooling checks:

- `python tools/autotrack_test_cli.py list`
- `python tools/autotrack_test_cli.py export-llm-trace` against an active Studio session

## Notes For Handoff

- Export JSON is intentionally only available through the test snapshot / CLI path, not normal gameplay UI state.
- If the bridge export path breaks, fix the maintained localhost bridge flow rather than adding a parallel ad hoc script path.
