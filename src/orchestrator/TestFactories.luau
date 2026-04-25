local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local EnduranceMemory = require(script.Parent.EnduranceMemory)

type OrchestratorContext = Types.OrchestratorContext

local TestFactories = {}

local DEFAULT_EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }

local function defaultSectorStates()
	local states = {}
	for _, sectorId in ipairs(DEFAULT_EDITABLE_SECTORS) do
		states[sectorId] = { mechanic = nil, params = {}, score = 0 }
	end
	return states
end

local function applyOverrides(target, overrides)
	for key, value in pairs(overrides or {}) do
		target[key] = value
	end
	return target
end

function TestFactories.emptyMemory()
	return EnduranceMemory.new()
end

function TestFactories.designIntent(overrides)
	return ContractBuilders.designIntent(applyOverrides({
		sector_id = 7,
		mechanic = "RampJump",
		params_hint = "extreme tall",
		rationale = "raise spectacle without repeating stale failures",
		target_score_band = "extreme",
		target_budget_tolerance = "medium",
		target_reliability = "balanced",
		spectacle_priority = "high",
		novelty_priority = "high",
		replacement_intent = "replace_if_gain",
		desired_feel = "big airtime but still recoverable",
		constraints = {
			"preserve downstream stability",
			"avoid overspending slowdown budget",
		},
	}, overrides))
end

function TestFactories.submitDecision(overrides)
	return ContractBuilders.submitDecision(applyOverrides({
		sector_id = 7,
		mechanic = "RampJump",
		params_hint = "extreme tall",
		rationale = "raise spectacle without repeating stale failures",
		target_score_band = "extreme",
		target_budget_tolerance = "medium",
		target_reliability = "balanced",
		spectacle_priority = "high",
		novelty_priority = "high",
		replacement_intent = "replace_if_gain",
		desired_feel = "big airtime but still recoverable",
		constraints = {
			"preserve downstream stability",
			"avoid overspending slowdown budget",
		},
	}, overrides))
end

function TestFactories.orchestratorContext(overrides): OrchestratorContext
	local context = {
		editable_sectors = table.clone(DEFAULT_EDITABLE_SECTORS),
		sector_states = defaultSectorStates(),
		budget = { used = 0.2, over_budget = false },
		attempt_budget = { used = 0, total = Constants.ENDURANCE_ATTEMPT_BUDGET },
		last_result = nil,
		attempt_history = {},
		sector_attempt_counts = {},
		mechanic_repeat_pressure = {},
		track_intent = {
			target_total_score = 0,
			target_budget_used = 0.2,
			diversity_pressure = {},
		},
		memory = EnduranceMemory.new(),
	}

	applyOverrides(context, overrides)
	if context.memory == nil then
		context.memory = EnduranceMemory.new()
	end
	return context
end

return TestFactories
