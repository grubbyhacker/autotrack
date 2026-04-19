# Phase 13 — Real LLM Integration

## Goal

Replace the heuristic proposer with calls to real language models via the OpenRouter API,
while keeping the heuristic as the default/safe path. LLM usage is off by default, toggled
from a new HUD control bar or via slash commands.

## Decisions

| Question | Decision |
|---|---|
| API key storage | `HttpService:GetSecret("OPENROUTER_API_KEY")` (Roblox secret store) |
| Default state | LLM disabled; heuristic is always the fallback mode |
| LLM failure behaviour | Report error in UI and abort the job (revert). No silent fallback. |
| Repair format | LLM returns a full revised SectorState (not a delta AgentAction) |
| Float lever values | Round to integer; per-model flag in LLMConfig for future relaxation |
| History depth | Up to 7 attempts passed as multi-turn conversation context |
| History scope | Current job only (cross-sector memory is Phase 14) |
| Unit test default | LLM disabled — tests use heuristic unless `AutoTrack_LLMEnabled=true` |

## Model list

| Display name | OpenRouter ID | integerLevers |
|---|---|---|
| Heuristic (built-in) | `heuristic` | — |
| Gemma 3 4B | `google/gemma-3-4b-it` | true |
| Gemma 4 31B | `google/gemma-4-31b-it:free` | true |
| Qwen Turbo | `qwen/qwen-turbo` | true |
| Claude 3 Haiku | `anthropic/claude-3-haiku` | false |

`integerLevers = false` means the LLM can return float lever values which are passed
through raw to the geometry builders (which are float-safe). Set to `true` for smaller
models that are less reliable with exact numeric JSON output.

## Architecture

### New modules

**`src/common/LLMConfig.luau`**
Central config module. Stores enabled flag, selected model ID, and the MODELS table.
`get()`, `setEnabled(bool)`, `setModel(id)` are the public API. Read from `LLMAdapter`
on every call — config changes take effect on the next job.

**`src/agent/OpenRouterProvider.luau`**
Server-only HTTP client. Reads `OPENROUTER_API_KEY` from Roblox secret store. Calls
`https://openrouter.ai/api/v1/chat/completions` with the selected model. Extracts the
first JSON object from the response (handles models that add prose around the JSON).
Rounds lever values to integer when `integerLevers = true`.

### Modified modules

**`src/agent/PromptBuilder.luau`**
Two new functions:
- `proposeMessages(request)` → message array for real LLM initial proposal
- `repairMessages(request, history, packet)` → multi-turn message array for repair

The existing `initialProposal()` and `repairStep()` string functions are kept as-is for
the mock/heuristic provider path.

**`src/agent/LLMAdapter.luau`**
- Reads `LLMConfig.get()` on every `propose()` / `repair()` call
- If disabled or model=`heuristic`: routes to existing mock (MinimalProposer) path
- Otherwise: instantiates `OpenRouterProvider` with the selected model ID
- `repair()` now accepts `history: { AttemptRecord }?` as second argument
- `repair()` now returns `(AgentAction?, SectorState?, explanation?, error?)`
  - Heuristic path: `(action, nil, explanation, nil)`
  - LLM path: `(nil, newSectorState, explanation, nil)`
  - Error: `(nil, nil, nil, errorString)`
- Rounds lever values to integer for models where `integerLevers = true`

**`src/common/Types.luau`**
- `AttemptRecord` gains a `proposed_state: SectorState` field so the LLM can see
  what geometry was attempted at each step

**`src/orchestrator/JobRunner.luau`**
- Captures `proposedState = cloneState(job.working_state)` before each `AttemptRunner.run`
  and stores it in the attempt record
- Passes `job.attempts` as history to `LLMAdapter.repair(packet, job.attempts)`
- Handles the two-path repair return: delta action (heuristic) or full state (LLM)
  - LLM path: sets `job.working_state = cloneState(newState)`, `nextAction = nil`
  - Delta path: validates and applies the action as before
- On repair error: sets `UIState.setError` before reverting so the error is visible
- New slash command: `/llm on|off|model <id>` (server-side control for testing)

**`src/orchestrator/UIState.luau`**
- Two new attributes: `llm_enabled` (bool), `llm_model` (string)
- `UIState.setLLMConfig(enabled, model)` writes both
- Included in `UIState.init()`

**`src/orchestrator/Main.server.luau`**
- Reads workspace attributes at boot:
  - `AutoTrack_LLMEnabled` (bool) → `LLMConfig.setEnabled()`
  - `AutoTrack_LLMModel` (string) → `LLMConfig.setModel()`
- Listens for `AutoTrack_SetLLMConfig` RemoteEvent: `{enabled, model}` table
  fired by client HUD controls
- Calls `UIState.setLLMConfig()` whenever config changes

**`src/ui/HUDRegistry.luau`**
- New LLM control bar (52px tall) inserted between the reasoning bar and the
  left/right rails
- Left/right rails shifted down by 62px to accommodate
- Control bar elements:
  - LLM toggle button (left, 80px wide): shows "LLM OFF" or "LLM ON"
  - Model name label (centre): shows "MODEL  <displayName>"
  - Previous/next model buttons (right, 30px each): cycle through MODELS list
- Exposed in refs as: `llmToggleButton`, `llmModelLabel`, `llmPrevButton`, `llmNextButton`

**`src/client/HUD.client.luau`**
- Listens to `llm_enabled` and `llm_model` attributes for render state
- Toggle button click: fires `AutoTrack_SetLLMConfig` with toggled enabled value
- Prev/next buttons: cycle model index, fire `AutoTrack_SetLLMConfig` with new model ID
- Adds `llm_enabled` and `llm_model` to observed attributes list

### New remote event

`AutoTrack_SetLLMConfig` (created in Main.server.luau)
- Client fires with: `{ enabled: boolean, model: string }`
- Server updates `LLMConfig`, then `UIState.setLLMConfig()`

## Multi-turn repair format

For an LLM repair at attempt N (with history), the messages sent are:

```
system: "You are the AutoTrack sector-design agent. Return ONLY a JSON SectorState..."
user:   "Initial proposal. Sector 3, RampJump, qualifiers: [extreme]..."
asst:   "{\"sector_id\":3,\"mechanic\":\"RampJump\",\"params\":{...},...}"
user:   "Attempt 0 failed. Failure: local_execution_failure. Hints: [gap too short]. Metrics: {...}"
asst:   "{...revised state...}"
user:   "Attempt 1 failed. Failure: ... Now provide a revised SectorState for attempt 2."
```

History is capped to `LLMConfig.MAX_HISTORY_DEPTH = 7` entries (most recent).

## Test coverage

**`src/orchestrator/TestPhase13.luau`**

Unit tests (no live LLM, skip_baseline):
1. `config_defaults_to_disabled` — LLMConfig.get() returns enabled=false, model="heuristic"
2. `config_set_enabled_and_model` — setEnabled/setModel work correctly
3. `config_invalid_model_ignored` — setModel with unknown ID is a no-op
4. `adapter_routes_to_heuristic_when_disabled` — LLMAdapter.getProviderName() returns "mock"
5. `adapter_routes_to_heuristic_when_model_is_heuristic` — even if enabled, heuristic model → mock path
6. `adapter_llm_path_selected_when_enabled` — LLMConfig enabled + real model → provider name is model ID
7. `attempt_record_includes_proposed_state` — after a job attempt, proposed_state is populated
8. `repair_returns_new_state_on_llm_path` — injected provider returning SectorState JSON → newState populated
9. `llm_error_reported_and_reverted` — injected provider throwing error → UIState has error text after revert

Integration test (opt-in, baseline required):
10. `llm_integration_propose_returns_valid_state` — with `AutoTrack_LLMEnabled=true` and
    `AutoTrack_LLMModel=google/gemma-3-4b-it`, submit a chicane request, verify committed
    state has valid schema. **Skipped automatically if `AutoTrack_LLMEnabled` ≠ true.**

## Test harness changes

- `tools/test_bridge_config.json` — adds `phase13_unit` (skip_baseline), `phase13_integration` (baseline)
- `Makefile` — adds `phase13_unit`, `phase13_integration` targets
- `src/orchestrator/TestDispatcher.luau` — adds `phase13`, `phase13_unit`, `phase13_integration` routes

## Phase 14 preview (not in scope)

The user noted that a follow-on feature would ask the LLM "what did you learn from this job?"
and pass the resulting summary as sector-level memory to future jobs on the same sector. This
mirrors the auto-memory system in this repository. Scope deferred to Phase 14.
