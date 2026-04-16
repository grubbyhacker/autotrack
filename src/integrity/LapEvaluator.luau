-- LapEvaluator.luau
-- Combines mechanic integrity and full-lap run outcome into a RunResult.
-- prd_plan.md §7.5, §11.1, Phase 5

local Types = require(script.Parent.Parent.common.Types)
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
-- lapFailure:   pre-existing failure detected during the run (or nil if lap completed)
-- targetState:  the SectorState that was under evaluation
-- metrics:      collected RunMetrics for this run
function LapEvaluator.evaluate(
	lapFailure: FailureInfo?,
	targetState: SectorState,
	metrics: RunMetrics
): RunResult
	-- If the lap itself failed, that takes precedence.
	if lapFailure then
		return { success = false, failure = lapFailure, metrics = metrics }
	end

	-- Lap completed — now check mechanic integrity.
	local evaluator = INTEGRITY_EVALUATORS[targetState.mechanic]
	assert(evaluator, "LapEvaluator: no integrity evaluator for " .. targetState.mechanic)

	local ok, hints = evaluator(targetState, metrics)
	if not ok then
		return {
			success = false,
			failure = {
				type = "mechanic_integrity_failure",
				sector_id = targetState.sector_id,
			},
			metrics = metrics,
		}
	end

	return { success = true, failure = nil, metrics = metrics }
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
	local legalLevers = {}
	-- Populate numeric levers from LevelMappings at call site to avoid circular deps
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
