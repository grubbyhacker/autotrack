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
type AttemptRecord = Types.AttemptRecord

local PromptBuilder = {}

local function encode(value): string
	return HttpService:JSONEncode(value)
end

-- System prompt for the mock/heuristic provider path (legacy string format).
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

local SCHEMA_LINE = "SectorState schema: {\"sector_id\":number,\"mechanic\":\"RampJump|Chicane|CrestDip\",\"params\":{},\"pads\":{\"ingress\":\"<PadValue>\",\"egress\":\"<PadValue>\"},\"version\":number}"
local PARAM_RANGES = table.concat({
	"Param ranges (always stay within range):",
	"  RampJump: ramp_angle 5-40 (default 20), ramp_length 4-28 (default 12), gap_length 2-24 (default 8), landing_length 4-28 (default 12).",
	"  Chicane:  amplitude 2-18 (default 5), transition_length 6-30 (default 15), corridor_width 8-22 (default 14).",
	"  CrestDip: height_or_depth 4-18 (default 8), radius 8-40 (default 20), sector_length 20-40 (default 30). CONSTRAINT: height_or_depth / sector_length^2 must be >= 0.006.",
}, "\n")

-- System prompt for initial proposals: be ambitious and creative.
local function llmProposeSystemPrompt(): string
	return table.concat({
		"You are the AutoTrack sector-design agent for a Roblox racing simulation.",
		"IMPORTANT: Your response must contain ONLY a valid JSON object. No prose, no markdown, no code fences.",
		"",
		"Your goal is to design an EXCITING, CHALLENGING obstacle that pushes the limits of what the verifier car can handle.",
		"The verifier car has fixed performance. Design for maximum spectacle — big air, tight chicanes, dramatic crests.",
		"Use qualifiers in the request to guide ambition: 'maximize' or 'extreme' means push params toward the top of their ranges.",
		"Do NOT anchor to defaults. Choose values that create a challenging, memorable obstacle.",
		"",
		"Supported mechanics: RampJump, Chicane, CrestDip.",
		"Pad values: " .. table.concat(PadValueUtils.allowedValues(), ", ") .. ".",
		SCHEMA_LINE,
		"",
		PARAM_RANGES,
	}, "\n")
end

-- System prompt for repair steps: be conservative and back off difficulty.
local function llmRepairSystemPrompt(): string
	return table.concat({
		"You are the AutoTrack sector-design agent for a Roblox racing simulation.",
		"IMPORTANT: Your response must contain ONLY a valid JSON object. No prose, no markdown, no code fences.",
		"",
		"CRITICAL CONSTRAINT: The verifier car has FIXED, UNCHANGEABLE performance (speed, acceleration, handling).",
		"The car FAILED. The obstacle is TOO DIFFICULT. You must make it EASIER.",
		"",
		"Failure interpretation guide:",
		"  off_track or lateral_error high → too wide/sharp; reduce amplitude (Chicane) or ramp_angle (RampJump)",
		"  vertical_displacement high or bad landing → ramp too steep or gap too long; reduce ramp_angle and/or gap_length",
		"  slowdown_ratio high → too much speed loss; reduce severity of all params",
		"  target_progress < 1 → car never reached the end; reduce ALL params toward defaults",
		"  When in doubt: move params TOWARD the defaults, not away from them.",
		"",
		"Supported mechanics: RampJump, Chicane, CrestDip.",
		"Pad values: " .. table.concat(PadValueUtils.allowedValues(), ", ") .. ".",
		SCHEMA_LINE,
		"",
		PARAM_RANGES,
		"",
		"Return a complete revised SectorState. Make small targeted changes — one or two params at a time.",
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

-- ── Real LLM message-array builders (Phase 13) ──────────────────────────────

-- Build the messages array for an initial proposal to a real LLM.
function PromptBuilder.proposeMessages(request: Request): { { role: string, content: string } }
	local userContent
	if request.parsed.request_kind == "Pad" then
		userContent = table.concat({
			"Initial proposal.",
			"Target sector: " .. tostring(request.parsed.sector_id),
			"Request kind: Pad",
			"Target pad side: " .. tostring(request.parsed.pad_side),
			"Target pad value: " .. tostring(request.parsed.pad_value),
			"Return a complete SectorState JSON with the requested pad change applied.",
		}, "\n")
	else
		local mechanic = request.parsed.mechanic
		local levers = LevelMappings.NUMERIC_LEVERS[mechanic]
		userContent = table.concat({
			"Initial proposal.",
			"Target sector: " .. tostring(request.parsed.sector_id),
			"Target mechanic: " .. mechanic,
			"Qualifiers: " .. encode(request.qualifiers),
			"Legal numeric levers: " .. encode(levers),
			"Return a complete SectorState JSON. Be ambitious — push params toward challenging values.",
		}, "\n")
	end
	return {
		{ role = "system", content = llmProposeSystemPrompt() },
		{ role = "user", content = userContent },
	}
end

-- Build the multi-turn messages array for a repair step.
-- history: the AttemptRecords from previous attempts in this job (capped externally).
-- packet: the current failure packet.
function PromptBuilder.repairMessages(request: Request, history: { AttemptRecord }, packet: FailurePacket): { { role: string, content: string } }
	local mechanic = packet.sector_state.mechanic
	local levers = mechanic and LevelMappings.NUMERIC_LEVERS[mechanic] or {}

	local messages = {}
	table.insert(messages, { role = "system", content = llmRepairSystemPrompt() })

	-- Turn 0: initial proposal request (reconstructed from request context)
	local initialUserContent = table.concat({
		"Initial proposal.",
		"Target sector: " .. tostring(request.parsed.sector_id),
		"Target mechanic: " .. tostring(mechanic),
		"Qualifiers: " .. encode(request.qualifiers),
		"Legal numeric levers: " .. encode(levers),
	}, "\n")
	table.insert(messages, { role = "user", content = initialUserContent })

	-- Interleave assistant proposals and user failure reports from history.
	for _, record in ipairs(history) do
		if record.proposed_state then
			table.insert(messages, { role = "assistant", content = encode(record.proposed_state) })
		end
		local result = record.result
		local failureType = result.failure and result.failure.type or "unknown"
		local failureDetail = result.failure and result.failure.detail or ""
		local hints = record.hints or {}
		local failureContent = string.format(
			"Attempt %d failed.\nfailure_type: %s\ndetail: %s\nhints: %s\nmetrics: %s",
			record.attempt_index,
			failureType,
			failureDetail ~= "" and failureDetail or "-",
			#hints > 0 and table.concat(hints, ", ") or "-",
			encode({
				slowdown_ratio = result.metrics.slowdown_ratio,
				target_progress = result.metrics.target_progress,
				air_distance = result.metrics.air_distance,
				lateral_error = result.metrics.lateral_error,
				vertical_displacement = result.metrics.vertical_displacement,
			})
		)
		table.insert(messages, { role = "user", content = failureContent })
	end

	-- Final user turn: request the revised state.
	-- Remind model of current params and direction: failures mean make it EASIER.
	local currentParams = packet.sector_state.params and encode(packet.sector_state.params) or "{}"
	local finalContent = string.format(
		"Provide a revised complete SectorState JSON for attempt %d.\n"
		.. "Sector %d, mechanic %s.\n"
		.. "Current params: %s\n"
		.. "The car FAILED — the obstacle is too hard. Reduce the difficulty: lower the values that make this mechanic more demanding.\n"
		.. "Make small changes to 1-2 params. Stay within the specified ranges.",
		packet.attempt_index + 1,
		packet.sector_state.sector_id,
		tostring(mechanic),
		currentParams
	)
	table.insert(messages, { role = "user", content = finalContent })

	return messages
end

return PromptBuilder
