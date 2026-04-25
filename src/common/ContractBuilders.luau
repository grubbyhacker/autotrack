--!strict
-- Small typed constructors for schema-shaped tables that cross module boundaries.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))

type AgentAction = Types.AgentAction
type DesignIntent = Types.DesignIntent
type Mechanic = Types.Mechanic
type MechanicParsedRequest = Types.MechanicParsedRequest
type MemoryEntry = Types.MemoryEntry
type OrchestratorLoopDecision = Types.OrchestratorLoopDecision
type OrchestratorSubmitDecision = Types.OrchestratorSubmitDecision
type PadParsedRequest = Types.PadParsedRequest
type PadSide = Types.PadSide
type PadValue = Types.PadValue
type ParsedRequest = Types.ParsedRequest
type PriorityLevel = Types.PriorityLevel
type ReplacementIntent = Types.ReplacementIntent
type Request = Types.Request
type RequestOrigin = Types.RequestOrigin
type RunMemory = Types.RunMemory
type TargetBudgetTolerance = Types.TargetBudgetTolerance
type TargetReliability = Types.TargetReliability
type TargetScoreBand = Types.TargetScoreBand

export type DesignIntentOptions = {
	sector_id: number,
	mechanic: Mechanic,
	params_hint: string,
	rationale: string?,
	target_score_band: TargetScoreBand?,
	target_budget_tolerance: TargetBudgetTolerance?,
	target_reliability: TargetReliability?,
	spectacle_priority: PriorityLevel?,
	novelty_priority: PriorityLevel?,
	replacement_intent: ReplacementIntent?,
	desired_feel: string?,
	constraints: { string }?,
}

export type RequestOptions = {
	request_id: string,
	raw_text: string,
	parsed: ParsedRequest,
	qualifiers: { string }?,
	origin: RequestOrigin?,
	design_intent: DesignIntent?,
	memory_context: RunMemory?,
	timestamp: number?,
}

export type EnduranceMechanicRequestOptions = {
	request_id: string,
	raw_text: string,
	design_intent: DesignIntent,
	qualifiers: { string }?,
	memory_context: RunMemory?,
	timestamp: number?,
}

local ContractBuilders = {}

local DEFAULT_CONSTRAINTS = {
	"preserve downstream stability",
	"stay within endurance budget",
}

local function cloneStringList(source: { string }?): { string }
	local result = {}
	for _, item in ipairs(source or DEFAULT_CONSTRAINTS) do
		table.insert(result, item)
	end
	return result
end

function ContractBuilders.mechanicParsedRequest(sectorId: number, mechanic: Mechanic): MechanicParsedRequest
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		request_kind = "Mechanic",
		pad_side = nil,
		pad_value = nil,
	}
end

function ContractBuilders.padParsedRequest(sectorId: number, side: PadSide, value: PadValue): PadParsedRequest
	return {
		sector_id = sectorId,
		mechanic = nil,
		request_kind = "Pad",
		pad_side = side,
		pad_value = value,
	}
end

function ContractBuilders.request(options: RequestOptions): Request
	return {
		request_id = options.request_id,
		raw_text = options.raw_text,
		parsed = options.parsed,
		qualifiers = cloneStringList(options.qualifiers or {}),
		origin = options.origin,
		design_intent = options.design_intent,
		memory_context = options.memory_context,
		timestamp = options.timestamp or os.time(),
	}
end

function ContractBuilders.playerMechanicRequest(
	requestId: string,
	rawText: string,
	sectorId: number,
	mechanic: Mechanic,
	qualifiers: { string }?,
	timestamp: number?
): Request
	return ContractBuilders.request({
		request_id = requestId,
		raw_text = rawText,
		parsed = ContractBuilders.mechanicParsedRequest(sectorId, mechanic),
		qualifiers = qualifiers or {},
		origin = "player",
		design_intent = nil,
		memory_context = nil,
		timestamp = timestamp,
	})
end

function ContractBuilders.playerPadRequest(
	requestId: string,
	rawText: string,
	sectorId: number,
	side: PadSide,
	value: PadValue,
	timestamp: number?
): Request
	return ContractBuilders.request({
		request_id = requestId,
		raw_text = rawText,
		parsed = ContractBuilders.padParsedRequest(sectorId, side, value),
		qualifiers = {},
		origin = "player",
		design_intent = nil,
		memory_context = nil,
		timestamp = timestamp,
	})
end

function ContractBuilders.designIntent(options: DesignIntentOptions): DesignIntent
	return {
		sector_id = options.sector_id,
		mechanic = options.mechanic,
		params_hint = options.params_hint,
		rationale = options.rationale or "push track variety without repeating stale failures",
		target_score_band = options.target_score_band or "high",
		target_budget_tolerance = options.target_budget_tolerance or "medium",
		target_reliability = options.target_reliability or "balanced",
		spectacle_priority = options.spectacle_priority or "high",
		novelty_priority = options.novelty_priority or "medium",
		replacement_intent = options.replacement_intent or "open_slot_preferred",
		desired_feel = options.desired_feel or "memorable but recoverable obstacle",
		constraints = cloneStringList(options.constraints),
	}
end

function ContractBuilders.submitDecision(
	options: DesignIntentOptions,
	memoryNote: MemoryEntry?
): OrchestratorSubmitDecision
	local intent = ContractBuilders.designIntent(options)
	return {
		action = "submit_request",
		sector_id = intent.sector_id,
		mechanic = intent.mechanic,
		params_hint = intent.params_hint,
		rationale = intent.rationale,
		target_score_band = intent.target_score_band,
		target_budget_tolerance = intent.target_budget_tolerance,
		target_reliability = intent.target_reliability,
		spectacle_priority = intent.spectacle_priority,
		novelty_priority = intent.novelty_priority,
		replacement_intent = intent.replacement_intent,
		desired_feel = intent.desired_feel,
		constraints = cloneStringList(intent.constraints),
		memory_note = memoryNote,
	}
end

function ContractBuilders.beginLoopDecision(rationale: string?, memoryNote: MemoryEntry?): OrchestratorLoopDecision
	return {
		action = "begin_loop",
		rationale = rationale,
		memory_note = memoryNote,
	}
end

function ContractBuilders.enduranceMechanicRequest(options: EnduranceMechanicRequestOptions): Request
	return ContractBuilders.request({
		request_id = options.request_id,
		raw_text = options.raw_text,
		parsed = ContractBuilders.mechanicParsedRequest(
			options.design_intent.sector_id,
			options.design_intent.mechanic
		),
		qualifiers = options.qualifiers or {},
		origin = "endurance",
		design_intent = ContractBuilders.designIntent(options.design_intent),
		memory_context = options.memory_context,
		timestamp = options.timestamp,
	})
end

function ContractBuilders.setNumericLever(lever: string, value: number): AgentAction
	return {
		type = "SetNumericLever",
		lever = lever,
		value = value,
	}
end

function ContractBuilders.setPad(side: PadSide, value: PadValue): AgentAction
	return {
		type = "SetPad",
		pad = side,
		value = value,
	}
end

return ContractBuilders
