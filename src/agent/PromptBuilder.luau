-- PromptBuilder.luau
-- Constructs the structured prompts sent to the LLM for initial proposals
-- and repair steps.
-- prd_plan.md §14, Phase 7

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local PadValueUtils = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("PadValueUtils"))

type Request = Types.Request
type FailurePacket = Types.FailurePacket

local PromptBuilder = {}

local function encode(value): string
	return HttpService:JSONEncode(value)
end

-- Build the system prompt (shared context about the game and schemas).
function PromptBuilder.systemPrompt(): string
	return table.concat({
		"You are the AutoTrack sector-design agent.",
		"Return JSON only with no prose outside the JSON object.",
		"Supported mechanics: RampJump, Chicane, CrestDip.",
		"Pad values: " .. table.concat(PadValueUtils.allowedValues(), ", ") .. ".",
		"You may remove a pad by setting it to None, or adjust strength by changing between the allowed pad values.",
		"Initial proposal must return a full SectorState for the requested sector and mechanic.",
		"Repair step must return exactly one AgentAction and a short explanation.",
	}, "\n")
end

-- Build the user turn for an initial proposal.
-- request: parsed request
-- defaults: default params for the mechanic (from LevelMappings.DEFAULTS)
function PromptBuilder.initialProposal(request: Request): string
	if request.parsed.request_kind == "Pad" then
		return table.concat({
			"Initial proposal request.",
			"Target sector: " .. tostring(request.parsed.sector_id),
			"Request kind: Pad",
			"Target pad side: " .. tostring(request.parsed.pad_side),
			"Target pad value: " .. tostring(request.parsed.pad_value),
			"Return a full SectorState for the sector with the requested pad change applied.",
			"Return JSON matching:",
			[[{"sector_id":number,"mechanic":"RampJump|Chicane|CrestDip|null","params":{},"pads":{"ingress":"None|Boost5|Boost10|Boost25|Brake5|Brake10|Brake25","egress":"None|Boost5|Boost10|Boost25|Brake5|Brake10|Brake25"},"version":number}]],
		}, "\n")
	end

	local mechanic = request.parsed.mechanic
	local defaults = LevelMappings.DEFAULTS[mechanic]
	local levers = LevelMappings.NUMERIC_LEVERS[mechanic]

	return table.concat({
		"Initial proposal request.",
		"Target sector: " .. tostring(request.parsed.sector_id),
		"Target mechanic: " .. mechanic,
		"Qualifiers: " .. encode(request.qualifiers),
		"Legal numeric levers: " .. encode(levers),
		"Default params: " .. encode(defaults),
		"Return JSON matching:",
		[[{"sector_id":number,"mechanic":"...","params":{},"pads":{"ingress":"None|Boost5|Boost10|Boost25|Brake5|Brake10|Brake25","egress":"None|Boost5|Boost10|Boost25|Brake5|Brake10|Brake25"},"version":number}]],
	}, "\n")
end

-- Build the user turn for a repair step.
function PromptBuilder.repairStep(packet: FailurePacket): string
	return table.concat({
		"Repair request.",
		"Attempt index: " .. tostring(packet.attempt_index),
		"Current sector state: " .. encode(packet.sector_state),
		"Run result: " .. encode(packet.run_result),
		"Diagnostics: " .. encode(packet.diagnostics),
		"Legal actions: " .. encode(packet.legal_actions),
		"Return JSON matching:",
		[[{"action":{"type":"SetNumericLever|SetPad"},"explanation":"short text"}]],
	}, "\n")
end

return PromptBuilder
