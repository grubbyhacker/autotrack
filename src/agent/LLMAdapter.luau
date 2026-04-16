-- LLMAdapter.luau
-- Narrow boundary between the CI orchestrator and the language model.
-- prd_plan.md §17 Phase 7
--
-- All LLM calls go through here.  The adapter is swappable:
-- swap out the implementation (Claude, Codex, mock) without touching
-- orchestrator logic.
--
-- Initial proposal:  receives a Request, returns a SectorState
-- Repair step:       receives a FailurePacket, returns an AgentAction
--
-- Both calls must validate structured output before returning.
-- Fail fast on invalid agent output — do not silently accept malformed data.

local Types = require(script.Parent.Parent.common.Types)
local PromptBuilder = require(script.Parent.PromptBuilder)
local ActionValidator = require(script.Parent.ActionValidator)

type Request = Types.Request
type SectorState = Types.SectorState
type AgentAction = Types.AgentAction
type FailurePacket = Types.FailurePacket

local LLMAdapter = {}

-- Request an initial SectorState proposal from the agent.
-- Returns (SectorState, nil) on success or (nil, errorString) on failure.
function LLMAdapter.propose(request: Request): (SectorState?, string?)
	-- TODO: Phase 7 — call LLM API, parse JSON response, validate via ActionValidator
	error("LLMAdapter.propose: not yet implemented")
end

-- Request a single repair AgentAction from the agent.
-- Returns (AgentAction, explanation) on success or (nil, errorString) on failure.
function LLMAdapter.repair(packet: FailurePacket): (AgentAction?, string?, string?)
	-- TODO: Phase 7 — call LLM API, parse JSON response, validate via ActionValidator
	-- Returns: action, short explanation string, error
	error("LLMAdapter.repair: not yet implemented")
end

return LLMAdapter
