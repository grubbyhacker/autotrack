local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local EnduranceObjective = require(script.Parent.EnduranceObjective)

type OrchestratorContext = Types.OrchestratorContext
type OrchestratorDecision = Types.OrchestratorDecision

local MinimalOrchestrator = {}

local PLAN = {
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

function MinimalOrchestrator.decide(context: OrchestratorContext): OrchestratorDecision
	if context.attempt_budget.used >= context.attempt_budget.total then
		return { action = "begin_loop" }
	end

	if context.budget.over_budget then
		return { action = "begin_loop" }
	end

	local fallbackDecision = nil
	for _, sectorId in ipairs(context.editable_sectors) do
		if not sectorIsFilled(context, sectorId) then
			local choice = PLAN[sectorId]
			local decision = {
				sector_id = sectorId,
				mechanic = choice.mechanic,
				params_hint = choice.params_hint,
			}
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

	return { action = "begin_loop" }
end

return MinimalOrchestrator
