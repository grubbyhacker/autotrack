--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local EnduranceMemory = require(script.Parent.EnduranceMemory)

type DesignIntent = Types.DesignIntent
type Mechanic = Types.Mechanic
type OrchestratorContext = Types.OrchestratorContext
type OrchestratorAttempt = Types.OrchestratorAttempt
type OrchestratorAttemptBudget = Types.OrchestratorAttemptBudget
type OrchestratorBudget = Types.OrchestratorBudget
type OrchestratorLastResult = Types.OrchestratorLastResult
type OrchestratorSectorSnapshot = Types.OrchestratorSectorSnapshot
type OrchestratorSubmitDecision = Types.OrchestratorSubmitDecision
type OrchestratorTrackIntent = Types.OrchestratorTrackIntent
type PriorityLevel = Types.PriorityLevel
type ReplacementIntent = Types.ReplacementIntent
type RunMemory = Types.RunMemory
type TargetBudgetTolerance = Types.TargetBudgetTolerance
type TargetReliability = Types.TargetReliability
type TargetScoreBand = Types.TargetScoreBand

export type DesignIntentOverrides = {
	sector_id: number?,
	mechanic: Mechanic?,
	params_hint: string?,
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

export type OrchestratorContextOverrides = {
	editable_sectors: { number }?,
	sector_states: { [number]: OrchestratorSectorSnapshot }?,
	budget: OrchestratorBudget?,
	attempt_budget: OrchestratorAttemptBudget?,
	last_result: OrchestratorLastResult?,
	attempt_history: { OrchestratorAttempt }?,
	sector_attempt_counts: { [number]: number }?,
	mechanic_repeat_pressure: { [string]: number }?,
	track_intent: OrchestratorTrackIntent?,
	memory: RunMemory?,
}

local TestFactories = {}

local DEFAULT_EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }

local function defaultSectorStates(): { [number]: OrchestratorSectorSnapshot }
	local states: { [number]: OrchestratorSectorSnapshot } = {}
	for _, sectorId in ipairs(DEFAULT_EDITABLE_SECTORS) do
		states[sectorId] = { mechanic = nil, params = {}, score = 0 }
	end
	return states
end

function TestFactories.emptyMemory(): RunMemory
	return EnduranceMemory.new()
end

function TestFactories.designIntent(overrides: DesignIntentOverrides?): DesignIntent
	local source: DesignIntentOverrides = overrides or {}
	return ContractBuilders.designIntent({
		sector_id = source.sector_id or 7,
		mechanic = source.mechanic or "RampJump",
		params_hint = source.params_hint or "extreme tall",
		rationale = source.rationale or "raise spectacle without repeating stale failures",
		target_score_band = source.target_score_band or "extreme",
		target_budget_tolerance = source.target_budget_tolerance or "medium",
		target_reliability = source.target_reliability or "balanced",
		spectacle_priority = source.spectacle_priority or "high",
		novelty_priority = source.novelty_priority or "high",
		replacement_intent = source.replacement_intent or "replace_if_gain",
		desired_feel = source.desired_feel or "big airtime but still recoverable",
		constraints = source.constraints or {
			"preserve downstream stability",
			"avoid overspending slowdown budget",
		},
	})
end

function TestFactories.submitDecision(overrides: DesignIntentOverrides?): OrchestratorSubmitDecision
	local source: DesignIntentOverrides = overrides or {}
	return ContractBuilders.submitDecision({
		sector_id = source.sector_id or 7,
		mechanic = source.mechanic or "RampJump",
		params_hint = source.params_hint or "extreme tall",
		rationale = source.rationale or "raise spectacle without repeating stale failures",
		target_score_band = source.target_score_band or "extreme",
		target_budget_tolerance = source.target_budget_tolerance or "medium",
		target_reliability = source.target_reliability or "balanced",
		spectacle_priority = source.spectacle_priority or "high",
		novelty_priority = source.novelty_priority or "high",
		replacement_intent = source.replacement_intent or "replace_if_gain",
		desired_feel = source.desired_feel or "big airtime but still recoverable",
		constraints = source.constraints or {
			"preserve downstream stability",
			"avoid overspending slowdown budget",
		},
	})
end

function TestFactories.orchestratorContext(overrides: OrchestratorContextOverrides?): OrchestratorContext
	local source: OrchestratorContextOverrides = overrides or {}
	return {
		editable_sectors = source.editable_sectors or table.clone(DEFAULT_EDITABLE_SECTORS),
		sector_states = source.sector_states or defaultSectorStates(),
		budget = source.budget or { used = 0.2, over_budget = false },
		attempt_budget = source.attempt_budget or { used = 0, total = Constants.ENDURANCE_ATTEMPT_BUDGET },
		last_result = source.last_result,
		attempt_history = source.attempt_history or {},
		sector_attempt_counts = source.sector_attempt_counts or {},
		mechanic_repeat_pressure = source.mechanic_repeat_pressure or {},
		track_intent = source.track_intent or {
			target_total_score = 0,
			target_budget_used = 0.2,
			diversity_pressure = {},
		},
		memory = source.memory or EnduranceMemory.new(),
	}
end

return TestFactories
