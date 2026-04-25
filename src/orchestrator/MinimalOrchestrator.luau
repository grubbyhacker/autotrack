--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local EnduranceObjective = require(script.Parent.EnduranceObjective)

type OrchestratorContext = Types.OrchestratorContext
type OrchestratorDecision = Types.OrchestratorDecision
type OrchestratorSubmitDecision = Types.OrchestratorSubmitDecision
type Mechanic = Types.Mechanic

local MinimalOrchestrator = {}

local PLAN: { [number]: { mechanic: Mechanic, params_hint: string } } = {
	[2] = { mechanic = "RampJump", params_hint = "extreme tall" },
	[3] = { mechanic = "CrestDip", params_hint = "extreme deep" },
	[4] = { mechanic = "Chicane", params_hint = "extreme tight" },
	[7] = { mechanic = "RampJump", params_hint = "extreme long" },
	[8] = { mechanic = "Chicane", params_hint = "extreme wide" },
	[9] = { mechanic = "CrestDip", params_hint = "extreme steep" },
}

local function sectorIsFilled(context: OrchestratorContext, sectorId: number): boolean
	local snapshot = context.sector_states[sectorId]
	return snapshot ~= nil and snapshot.mechanic ~= nil
end

local function buildIntent(sectorId: number, mechanic: Mechanic, paramsHint: string): OrchestratorSubmitDecision
	return ContractBuilders.submitDecision({
		sector_id = sectorId,
		mechanic = mechanic,
		params_hint = paramsHint,
		rationale = "push track variety without repeating stale failures",
		target_score_band = "high",
		target_budget_tolerance = "medium",
		target_reliability = "balanced",
		spectacle_priority = "high",
		novelty_priority = "medium",
		replacement_intent = "open_slot_preferred",
		desired_feel = "memorable but recoverable obstacle",
		constraints = {
			"preserve downstream stability",
			"stay within endurance budget",
		},
	})
end

function MinimalOrchestrator.decide(context: OrchestratorContext): OrchestratorDecision
	if context.attempt_budget.used >= context.attempt_budget.total then
		return ContractBuilders.beginLoopDecision()
	end

	if context.budget.over_budget then
		return ContractBuilders.beginLoopDecision()
	end

	local fallbackDecision = nil
	for _, sectorId in ipairs(context.editable_sectors) do
		if not sectorIsFilled(context, sectorId) then
			local choice = PLAN[sectorId]
			local decision = buildIntent(sectorId, choice.mechanic, choice.params_hint)
			if fallbackDecision == nil then
				fallbackDecision = decision
			end
			if not EnduranceObjective.shouldAvoidRepeat(context, decision) then
				return decision
			end
		end
	end

	if fallbackDecision ~= nil then
		return fallbackDecision
	end

	return ContractBuilders.beginLoopDecision()
end

return MinimalOrchestrator
