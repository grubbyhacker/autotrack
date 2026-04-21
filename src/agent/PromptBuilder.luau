-- PromptBuilder.luau
-- Constructs the structured prompts sent to the LLM for initial proposals
-- and repair steps.
-- prd_plan.md §14, Phase 7

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
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
		"Repair step may return either one AgentAction with a short explanation or a complete revised SectorState.",
	}, "\n")
end

local SCHEMA_LINE = "SectorState schema: {\"sector_id\":number,\"mechanic\":\"RampJump|Chicane|CrestDip\",\"params\":{},\"pads\":{\"ingress\":\"<PadValue>\",\"egress\":\"<PadValue>\"},\"version\":number}"
local function paramRangeLine(mechanic: string, levers: { string }): string
	local defaults = LevelMappings.DEFAULTS[mechanic]
	local bounds = LevelMappings.LEVER_BOUNDS[mechanic]
	local parts = {}
	for _, lever in ipairs(levers) do
		local bound = bounds[lever]
		table.insert(parts, string.format(
			"%s %d-%d (default %d)",
			lever,
			bound.min,
			bound.max,
			defaults[lever]
		))
	end
	local suffix = "."
	if mechanic == "CrestDip" then
		suffix = string.format(
			". CONSTRAINT: height_or_depth / sector_length^2 must be >= %.3f.",
			Constants.CRESTDIP_MIN_CURVATURE
		)
	end
	return string.format("  %s: %s%s", mechanic, table.concat(parts, ", "), suffix)
end

local PARAM_RANGES = table.concat({
	"Param ranges (always stay within range):",
	paramRangeLine("RampJump", LevelMappings.NUMERIC_LEVERS.RampJump),
	paramRangeLine("Chicane", LevelMappings.NUMERIC_LEVERS.Chicane),
	paramRangeLine("CrestDip", LevelMappings.NUMERIC_LEVERS.CrestDip),
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
		"  tumble, spinout, overturn, backward_facing, invalid_attitude → entry/setup unstable; prefer braking entry and softening geometry, not adding speed",
		"  vertical_displacement high or bad landing → ramp too steep or gap too long; reduce ramp_angle and/or gap_length",
		"  slowdown_ratio high → too much speed loss; reduce severity of all params",
		"  target_progress < 1 → car never reached the end; reduce ALL params toward defaults",
		"  downstream_failure → your sector passed but harmed a later committed sector; preserve exit speed and post-feature stability",
		"  For downstream_failure, avoid adding egress brake unless diagnostics say exit attitude was unstable.",
		"  For CrestDip specifically: do not add an egress brake by default. Prefer ingress brake plus softer geometry for crash repair; use egress brake only when diagnostics explicitly say the exit attitude is unstable.",
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

local function compactMetrics(metrics): string
	return encode({
		entry_speed = metrics.entry_speed,
		exit_speed = metrics.exit_speed,
		target_progress = metrics.target_progress,
		target_entered = metrics.target_entered,
		target_exited = metrics.target_exited,
		target_reacquired = metrics.target_reacquired,
		target_airtime_distance = metrics.target_airtime_distance,
		target_vertical_displacement = metrics.target_vertical_displacement,
		target_apex_min_speed = metrics.target_apex_min_speed,
		slowdown_ratio = metrics.slowdown_ratio,
	})
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
			[[{"sector_id":number,"mechanic":"RampJump|Chicane|CrestDip|null","params":{},"pads":{"ingress":"<PadValue>","egress":"<PadValue>"},"version":number}]],
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
		[[{"sector_id":number,"mechanic":"...","params":{},"pads":{"ingress":"<PadValue>","egress":"<PadValue>"},"version":number}]],
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
				compactMetrics(result.metrics)
			)
			table.insert(messages, { role = "user", content = failureContent })
	end

	-- Final user turn: request the revised state.
	-- Remind model of current params and direction: failures mean make it EASIER.
	local currentParams = packet.sector_state.params and encode(packet.sector_state.params) or "{}"
	local finalLines = {
		string.format("Provide a revised complete SectorState JSON for attempt %d.", packet.attempt_index + 1),
		string.format("Sector %d, mechanic %s.", packet.sector_state.sector_id, tostring(mechanic)),
		"Current params: " .. currentParams,
		"Current pads: " .. encode(packet.sector_state.pads),
		"Current run metrics: " .. compactMetrics(packet.run_result.metrics),
		"Diagnostics: " .. encode(packet.diagnostics),
		"The car FAILED — make the obstacle easier.",
		"If this is a downstream_failure, your sector already passed but harmed a later committed sector. Preserve downstream compatibility, especially exit speed and post-feature stability.",
		"Make small changes to 1-2 params or pads. Stay within the specified ranges.",
	}
	if packet.diagnostics.downstream_sector_state ~= nil then
		table.insert(finalLines, "Downstream committed sector: " .. encode(packet.diagnostics.downstream_sector_state))
	end
	local finalContent = table.concat(finalLines, "\n")
	table.insert(messages, { role = "user", content = finalContent })

	return messages
end

return PromptBuilder
