-- LapEvaluator.luau
-- Combines mechanic integrity and full-lap run outcome into a RunResult.
-- prd_plan.md §7.5, §11.1, Phase 5

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local RampJumpIntegrity = require(script.Parent.RampJumpIntegrity)
local ChicaneIntegrity  = require(script.Parent.ChicaneIntegrity)
local CrestDipIntegrity = require(script.Parent.CrestDipIntegrity)
local ChallengeScore    = require(script.Parent.ChallengeScore)

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

local RUNTIME_EVALUATORS = {
	RampJump = RampJumpIntegrity.evaluateRuntime,
	Chicane = ChicaneIntegrity.evaluateRuntime,
	CrestDip = CrestDipIntegrity.evaluateRuntime,
}

local function zeroMetrics(): RunMetrics
	return {
		entry_speed = 0,
		exit_speed = 0,
		airborne = false,
		air_distance = 0,
		lateral_error = 0,
		vertical_displacement = 0,
		reacquired = true,
		airtime_distance = 0,
		target_airborne = false,
		target_air_distance = 0,
		target_vertical_displacement = 0,
		target_reacquired = true,
		target_airtime_distance = 0,
		target_left_offset = 0,
		target_right_offset = 0,
		target_lateral_band_changes = 0,
		target_entered = false,
		target_exited = false,
		target_progress = 0,
		target_reacquire_distance = 0,
		target_peak_body_distance = 0,
		target_exit_angular_speed = 0,
		target_exit_vertical_speed = 0,
		lap_time = 0,
		slowdown_ratio = 1,
	}
end

function LapEvaluator.preflight(
	targetState: SectorState,
	targetSectorId: number
): (RunResult?, { string })
	if targetState.mechanic == nil then
		return nil, {}
	end

	if targetState.mechanic == "CrestDip" then
		local ok, hints = CrestDipIntegrity.preflight(targetState)
		if not ok then
			return {
				success = false,
				failure = {
					type = "mechanic_integrity_failure",
					sector_id = targetSectorId,
				},
				metrics = zeroMetrics(),
			}, hints
		end
	elseif targetState.mechanic == "RampJump" then
		local ok, hints = RampJumpIntegrity.preflight(targetState)
		if not ok then
			return {
				success = false,
				failure = {
					type = "mechanic_integrity_failure",
					sector_id = targetSectorId,
				},
				metrics = zeroMetrics(),
			}, hints
		end
	elseif targetState.mechanic == "Chicane" then
		local ok, hints = ChicaneIntegrity.preflight(targetState)
		if not ok then
			return {
				success = false,
				failure = {
					type = "mechanic_integrity_failure",
					sector_id = targetSectorId,
				},
				metrics = zeroMetrics(),
			}, hints
		end
	end
	return nil, {}
end

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
	targetSectorId: number,
	earlyHints: { string }?
): (RunResult, { string })
	-- Reclassify local_execution_failure in a non-target sector as downstream_failure.
	if lapFailure then
		local failure = lapFailure
		if failure.type == "local_execution_failure"
			and failure.sector_id ~= targetSectorId
			and metrics.target_entered == true then
			local runtimeEvaluator = targetState.mechanic and RUNTIME_EVALUATORS[targetState.mechanic]
			if runtimeEvaluator then
				local runtimeOk, runtimeHints = runtimeEvaluator(metrics)
				if not runtimeOk then
					return {
						success = false,
						failure = {
							type = "mechanic_integrity_failure",
							sector_id = targetSectorId,
						},
						metrics = metrics,
					}, runtimeHints
				end
			end
			if metrics.target_exited == true then
				failure = { type = "downstream_failure", sector_id = failure.sector_id }
			end
		end
		return { success = false, failure = failure, metrics = metrics }, earlyHints or {}
	end

	if targetState.mechanic == nil then
		return {
			success = true,
			failure = nil,
			metrics = metrics,
			score = ChallengeScore.compute(targetState, metrics),
		}, {}
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

	return {
		success = true,
		failure = nil,
		metrics = metrics,
		score = ChallengeScore.compute(targetState, metrics),
	}, {}
end

-- Build a FailurePacket for the repair agent from a failed RunResult.
function LapEvaluator.buildFailurePacket(
	request: Types.Request,
	state: SectorState,
	attemptIndex: number,
	lastAction: Types.AgentAction?,
	result: RunResult,
	failureSector: number,
	hints: { string },
	extraDiagnostics
): Types.FailurePacket
	local legalLevers = LevelMappings.NUMERIC_LEVERS[state.mechanic] or {}
	local diagnosticHints = {}
	for _, hint in ipairs(hints) do
		table.insert(diagnosticHints, hint)
	end

	local detail = result.failure and result.failure.detail
	if type(detail) == "string" and detail ~= "" then
		local seen = false
		for _, hint in ipairs(diagnosticHints) do
			if hint == detail then
				seen = true
				break
			end
		end
		if not seen then
			table.insert(diagnosticHints, detail)
		end
	end

	local targetExitSpeed = result.metrics.exit_speed or 0
	local targetReacquired = result.metrics.target_reacquired
	if result.failure and result.failure.type == "downstream_failure" then
		if targetExitSpeed > 0 and targetExitSpeed < Constants.CAR_TARGET_SPEED * 0.75 then
			table.insert(diagnosticHints, "target sector exit speed too low for downstream")
		end
		if targetReacquired == false then
			table.insert(diagnosticHints, "target sector exit attitude unstable")
		end
	end

	local diagnostics = {
		failure_sector = failureSector,
		hints = diagnosticHints,
		failure_type = result.failure and result.failure.type or nil,
		failure_detail = detail,
		target_entry_speed = result.metrics.entry_speed,
		target_exit_speed = result.metrics.exit_speed,
		target_reacquired = result.metrics.target_reacquired,
		target_airtime_distance = result.metrics.target_airtime_distance,
		target_apex_min_speed = result.metrics.target_apex_min_speed,
	}
	if type(extraDiagnostics) == "table" then
		for key, value in pairs(extraDiagnostics) do
			diagnostics[key] = value
		end
	end

	return {
		request       = request,
		sector_state  = state,
		attempt_index = attemptIndex,
		last_action   = lastAction,
		run_result    = result,
		diagnostics   = diagnostics,
		legal_actions = { numeric_levers = legalLevers, pads = { "ingress", "egress" } },
		design_intent = request.design_intent,
		memory_context = request.memory_context,
	}
end

return LapEvaluator
