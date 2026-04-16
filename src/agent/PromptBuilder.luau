-- PromptBuilder.luau
-- Constructs the structured prompts sent to the LLM for initial proposals
-- and repair steps.
-- prd_plan.md §14, Phase 7

local Types = require(script.Parent.Parent.common.Types)
local LevelMappings = require(script.Parent.Parent.common.LevelMappings)

type Request = Types.Request
type FailurePacket = Types.FailurePacket

local PromptBuilder = {}

-- Build the system prompt (shared context about the game and schemas).
function PromptBuilder.systemPrompt(): string
	-- TODO: Phase 7
	error("PromptBuilder.systemPrompt: not yet implemented")
end

-- Build the user turn for an initial proposal.
-- request: parsed request
-- defaults: default params for the mechanic (from LevelMappings.DEFAULTS)
function PromptBuilder.initialProposal(request: Request): string
	-- TODO: Phase 7 — include mechanic name, sector_id, qualifiers, legal levers,
	-- default values, and ask for a full SectorState JSON
	error("PromptBuilder.initialProposal: not yet implemented")
end

-- Build the user turn for a repair step.
function PromptBuilder.repairStep(packet: FailurePacket): string
	-- TODO: Phase 7 — include current SectorState, diagnostics, hints,
	-- attempt index, and ask for exactly one AgentAction JSON
	error("PromptBuilder.repairStep: not yet implemented")
end

return PromptBuilder
