--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local JobRunner = require(script.Parent.JobRunner)
local OrchestratorAgent = require(script.Parent.OrchestratorAgent)
local T = require(script.Parent.TestUtils)

local TestPhase24 = {}

type AgentAction = Types.AgentAction
type FailureType = Types.FailureType
type RunResult = Types.RunResult
type SectorState = Types.SectorState

local function cloneState(state: SectorState): SectorState
	return {
		sector_id = state.sector_id,
		mechanic = state.mechanic,
		params = table.clone(state.params),
		pads = {
			ingress = state.pads.ingress,
			egress = state.pads.egress,
		},
		version = state.version,
	}
end

local function baseState(): SectorState
	return {
		sector_id = 3,
		mechanic = "RampJump",
		params = {
			ramp_angle = 12,
			ramp_length = 18,
			gap_length = 4,
			landing_length = 20,
		},
		pads = {
			ingress = "None",
			egress = "None",
		},
		version = 1,
	}
end

local function result(success: boolean, failureType: FailureType?, failureSector: number?, detail: string?): RunResult
	return {
		success = success,
		failure = if success
			then nil
			else {
				type = failureType or "local_execution_failure",
				sector_id = failureSector or 3,
				detail = detail,
			},
		metrics = {
			entry_speed = 80,
			exit_speed = 70,
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
			target_entered = true,
			target_exited = success,
			target_progress = if success then 1 else 0.4,
			target_reacquire_distance = 0,
			target_peak_body_distance = 0,
			target_exit_angular_speed = 0,
			target_exit_vertical_speed = 0,
			lap_time = if success then 24 else 15,
			slowdown_ratio = if success then 1.08 else 1.02,
		},
	}
end

local function testIsolatedThenCommitLap()
	local calls: { string } = {}
	local actionApplyCount = 0
	local action = ContractBuilders.setNumericLever("ramp_angle", 14)

	local summary = JobRunner._runVerificationProfile({
		use_isolated_profile = true,
		working_state = baseState(),
		action = action,
		runAttempt = function(mode: string, state: SectorState, actionForRun: AgentAction?)
			table.insert(calls, mode)
			local updated = cloneState(state)
			if
				actionForRun ~= nil
				and actionForRun.type == "SetNumericLever"
				and actionForRun.lever == "ramp_angle"
			then
				actionApplyCount += 1
				updated.params.ramp_angle = actionForRun.value
			end
			if mode == "full_lap" then
				return result(true), {}, updated
			end
			return result(true), {}, updated
		end,
	})

	T.expect(
		"phase24_isolated_then_commit_lap_order",
		#calls == 4
			and calls[1] == "isolated_sector"
			and calls[2] == "isolated_sector"
			and calls[3] == "isolated_sector"
			and calls[4] == "full_lap",
		table.concat(calls, ",")
	)
	T.expect(
		"phase24_isolated_then_commit_lap_applies_action_once",
		actionApplyCount == 1 and summary.updated_state.params.ramp_angle == 14,
		string.format(
			"actionApplyCount=%d ramp_angle=%s",
			actionApplyCount,
			tostring(summary.updated_state.params.ramp_angle)
		)
	)
	T.expect(
		"phase24_isolated_then_commit_lap_stage_metadata",
		summary.result.success == true
			and summary.verification_stage == "commit_lap"
			and summary.run_scope == "lap"
			and summary.isolated_passes_required == 3
			and summary.isolated_passes_completed == 3,
		tostring(summary.verification_stage) .. "/" .. tostring(summary.run_scope)
	)
end

local function testIsolatedFailureSkipsCommitLap()
	local calls: { string } = {}
	local summary = JobRunner._runVerificationProfile({
		use_isolated_profile = true,
		working_state = baseState(),
		action = nil,
		runAttempt = function(mode: string, state: SectorState, _actionForRun: AgentAction?)
			table.insert(calls, mode)
			local updated = cloneState(state)
			if mode == "isolated_sector" then
				return result(false, "local_execution_failure", 3, "no_progress"), { "isolated fail" }, updated
			end
			return result(true), {}, updated
		end,
	})

	T.expect(
		"phase24_isolated_failure_short_circuits_commit_lap",
		#calls == 1 and calls[1] == "isolated_sector",
		table.concat(calls, ",")
	)
	T.expect(
		"phase24_isolated_failure_stage_metadata",
		summary.result.success == false
			and summary.verification_stage == "isolated"
			and summary.run_scope == "isolated_sector"
			and summary.isolated_passes_completed == 1
			and summary.isolated_passes_required == 3
			and #summary.hints == 1,
		tostring(summary.verification_stage) .. "/" .. tostring(summary.run_scope)
	)
end

local function testCommitLapFailureSurfacesAsCommitStage()
	local calls: { string } = {}
	local summary = JobRunner._runVerificationProfile({
		use_isolated_profile = true,
		working_state = baseState(),
		action = nil,
		runAttempt = function(mode: string, state: SectorState, _actionForRun: AgentAction?)
			table.insert(calls, mode)
			local updated = cloneState(state)
			if mode == "full_lap" then
				return result(false, "downstream_failure", 7, "target sector exit speed too low for downstream"),
					{ "downstream" },
					updated
			end
			return result(true), {}, updated
		end,
	})

	T.expect(
		"phase24_commit_lap_failure_runs_after_isolated_success",
		#calls == 4 and calls[4] == "full_lap",
		table.concat(calls, ",")
	)
	T.expect(
		"phase24_commit_lap_failure_stage_metadata",
		summary.result.success == false
			and summary.verification_stage == "commit_lap"
			and summary.run_scope == "lap"
			and summary.isolated_passes_completed == 3,
		tostring(summary.verification_stage) .. "/" .. tostring(summary.run_scope)
	)
end

local function testNonEnduranceStaysSingleLap()
	local calls: { string } = {}
	local action = ContractBuilders.setPad("ingress", "Boost10")
	local sawAction = false

	local summary = JobRunner._runVerificationProfile({
		use_isolated_profile = false,
		working_state = baseState(),
		action = action,
		runAttempt = function(mode: string, state: SectorState, actionForRun: AgentAction?)
			table.insert(calls, mode)
			local updated = cloneState(state)
			if actionForRun ~= nil and actionForRun.type == "SetPad" then
				sawAction = true
				updated.pads[actionForRun.pad] = actionForRun.value
			else
				sawAction = false
			end
			return result(true), {}, updated
		end,
	})

	T.expect(
		"phase24_non_endurance_single_full_lap",
		#calls == 1 and calls[1] == "full_lap" and sawAction,
		table.concat(calls, ",")
	)
	T.expect(
		"phase24_non_endurance_stage_metadata",
		summary.verification_stage == "lap"
			and summary.run_scope == "lap"
			and summary.isolated_passes_required == nil
			and summary.isolated_passes_completed == nil,
		tostring(summary.verification_stage) .. "/" .. tostring(summary.run_scope)
	)
end

local function testBudgetRefreshUsesCommittedFullLapOnly()
	local previous = 1.18
	local committedJob = {
		final_status = "committed",
		final_result = {
			metrics = {
				slowdown_ratio = 1.06,
			},
		},
	}
	local revertedJob = {
		final_status = "reverted",
		final_result = {
			metrics = {
				slowdown_ratio = 0.92,
			},
		},
	}

	T.expect(
		"phase24_budget_refresh_uses_committed_full_lap",
		OrchestratorAgent._commitLapSlowdownRatio(previous, committedJob) == 1.06,
		tostring(OrchestratorAgent._commitLapSlowdownRatio(previous, committedJob))
	)
	T.expect(
		"phase24_budget_refresh_ignores_non_committed_job",
		OrchestratorAgent._commitLapSlowdownRatio(previous, revertedJob) == previous,
		tostring(OrchestratorAgent._commitLapSlowdownRatio(previous, revertedJob))
	)
	T.expect(
		"phase24_budget_refresh_ignores_missing_final_result",
		OrchestratorAgent._commitLapSlowdownRatio(previous, { final_status = "committed", final_result = nil })
			== previous,
		tostring(
			OrchestratorAgent._commitLapSlowdownRatio(previous, { final_status = "committed", final_result = nil })
		)
	)
end

function TestPhase24.run()
	testIsolatedThenCommitLap()
	testIsolatedFailureSkipsCommitLap()
	testCommitLapFailureSurfacesAsCommitStage()
	testNonEnduranceStaysSingleLap()
	testBudgetRefreshUsesCommittedFullLapOnly()
end

return TestPhase24
