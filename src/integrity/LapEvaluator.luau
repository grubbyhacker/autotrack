-- LapEvaluator.luau
-- Combines mechanic integrity and full-lap run outcome into a RunResult.
-- prd_plan.md §7.5, §11.1, Phase 5

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local RampJumpIntegrity = require(script.Parent.RampJumpIntegrity)
local ChicaneIntegrity  = require(script.Parent.ChicaneIntegrity)
local CrestDipIntegrity = require(script.Parent.CrestDipIntegrity)

type SectorState = Types.SectorState
type RunMetrics  = Types.RunMetrics
type RunResult   = Types.RunResult
type FailureInfo = Types.FailureInfo

local LapEvaluator = {}

local INTEGRITY_EVALUATORS = {
	RampJump = RampJumpIntegrity.evaluate,
	Chicane  = ChicaneIntegrity.evaluate,
	CrestDip = CrestDipIntegrity.evaluate,
}

-- Produce a RunResult given the raw lap outcome.
-- lapFailure:     pre-existing failure detected during the run (or nil if lap completed)
-- targetState:    the SectorState that was under evaluation
-- metrics:        collected RunMetrics for this run
-- targetSectorId: the sector being tested (used for downstream_failure reclassification)
--
-- Returns (RunResult, hints). hints is non-empty only on mechanic_integrity_failure.
function LapEvaluator.evaluate(
	lapFailure: FailureInfo?,
	targetState: SectorState,
	metrics: RunMetrics,
	targetSectorId: number
): (RunResult, { string })
	-- Reclassify local_execution_failure in a non-target sector as downstream_failure.
	if lapFailure then
		local failure = lapFailure
		if failure.type == "local_execution_failure" and failure.sector_id ~= targetSectorId then
			failure = { type = "downstream_failure", sector_id = failure.sector_id }
		end
		return { success = false, failure = failure, metrics = metrics }, {}
	end

	-- Lap completed — now check mechanic integrity.
	local evaluator = INTEGRITY_EVALUATORS[targetState.mechanic]
	assert(evaluator, "LapEvaluator: no integrity evaluator for " .. tostring(targetState.mechanic))

	local ok, hints = evaluator(targetState, metrics)
	if not ok then
		return {
			success = false,
			failure = {
				type = "mechanic_integrity_failure",
				sector_id = targetSectorId,
			},
			metrics = metrics,
		}, hints
	end

	return { success = true, failure = nil, metrics = metrics }, {}
end

-- Build a FailurePacket for the repair agent from a failed RunResult.
function LapEvaluator.buildFailurePacket(
	request: Types.Request,
	state: SectorState,
	attemptIndex: number,
	lastAction: Types.AgentAction?,
	result: RunResult,
	failureSector: number,
	hints: { string }
): Types.FailurePacket
	local legalLevers = LevelMappings.NUMERIC_LEVERS[state.mechanic] or {}
	return {
		request       = request,
		sector_state  = state,
		attempt_index = attemptIndex,
		last_action   = lastAction,
		run_result    = result,
		diagnostics   = { failure_sector = failureSector, hints = hints },
		legal_actions = { numeric_levers = legalLevers, pads = { "ingress", "egress" } },
	}
end

return LapEvaluator
