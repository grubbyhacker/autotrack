# Phase 19 — Endurance Design Intent Handoff

## Summary

Phase 19 upgrades endurance mode from a loose relay of prompts into a coherent
multi-agent chain by introducing a shared structured `DesignIntent` object that
flows from `orchestrate` to `propose` to `repair`.

This phase is intentionally scoped to intent continuity, not the broader
memory-system ideas from `docs/endurance-agent-fidelity.md`. The current
orchestrator history and repair history stay in place; Phase 19 makes the
downstream agents consume the orchestrator's actual brief instead of
reconstructing it from a thin English request string.

The internal canonical path becomes:

1. `orchestrate(context) -> DesignIntent`
2. server submits an endurance job from that `DesignIntent` directly
3. `propose(request, design_intent)` builds the initial `SectorState`
4. `repair(packet, history, design_intent)` revises while preserving the same
   brief

Human-readable request text remains a derived HUD/log artifact only.

## Public Interface / Type Changes

- Add `DesignIntent` to `src/common/Types.luau`:
  - `sector_id`
  - `mechanic`
  - `params_hint`
  - `rationale`
  - `target_score_band`
  - `target_budget_tolerance`
  - `target_reliability`
  - `spectacle_priority`
  - `novelty_priority`
  - `replacement_intent`
  - `desired_feel`
  - `constraints`
- Extend `OrchestratorDecision` so the orchestration response is effectively a
  `DesignIntent` or `{ action = "begin_loop", rationale = ... }`.
- Extend `Request` with optional endurance-origin metadata:
  - `origin = "player" | "endurance"`
  - `design_intent: DesignIntent?`
- Extend `FailurePacket` with `design_intent: DesignIntent?` so repair always
  sees the same brief.
- Update `LLMAdapter` signatures:
  - `propose(request, designIntent?)`
  - `repair(packet, history, designIntent?)`
- Add a direct endurance submission path in `JobRunner` for structured jobs, so
  endurance no longer depends on `RequestParser` roundtripping its own decision
  text.

## Implementation Changes

- Update `OrchestratorPromptBuilder` to request a full `DesignIntent` JSON
  object, not only `sector_id/mechanic/params_hint`.
- Update `PromptBuilder.proposeMessages` to include the shared `DesignIntent`
  explicitly and instruct the proposer to implement that brief locally.
- Update `PromptBuilder.repairMessages` to include the same `DesignIntent` and
  instruct the repair agent to preserve the brief unless current evidence forces
  softening.
- Make `OrchestratorAgent` receive `DesignIntent`, compute derived English
  request text only for logs/HUD, and submit the job through a direct structured
  API.
- Make `JobRunner` accept either existing parsed text requests or a prebuilt
  endurance request carrying `design_intent`.
- Keep player jobs on the existing text-parsing path.
- Keep `LLMAdapter` as the only LLM boundary.
- Extend LLM trace prompt payloads so `design_intent` is visible on
  `orchestrate`, `propose`, and `repair` calls.

## Test Plan

- Add `src/orchestrator/TestPhase19.luau`, plus `TestDispatcher`,
  `tools/test_bridge_config.json`, and `Makefile` wiring.
- Add prompt-content assertions:
  - `phase19_orchestrator_prompt_requests_full_design_intent`
  - `phase19_propose_messages_include_design_intent`
  - `phase19_repair_messages_include_same_design_intent`
  - `phase19_repair_messages_preserve_constraints_language`
  - `phase19_trace_records_design_intent_for_all_roles`
  - `phase19_prompt_content_omits_string_roundtrip_dependency`
- Add flow / validation assertions:
  - `phase19_orchestrate_returns_design_intent`
  - `phase19_endurance_submit_bypasses_request_roundtrip`
  - `phase19_player_text_path_unchanged`
  - `phase19_invalid_design_intent_rejected`
  - `phase19_begin_loop_still_supported`

## Verification

- `make test TEST=phase19`
- `make test TEST=phase13_unit`
- `make test TEST=phase14_5`
- `make test TEST=phase18`

## Assumptions

- Phase 19 does not add shared free-text notebooks or role-local memory
  buffers; that is deferred.
- `DesignIntent` is session-local and ephemeral.
- `desired_feel`, `rationale`, and `constraints` stay short and bounded.
- HUD may continue showing derived request text, but endurance execution
  authority moves to the structured handoff object.
