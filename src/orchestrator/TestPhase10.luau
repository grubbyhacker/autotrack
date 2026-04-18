local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local T = require(script.Parent.TestUtils)
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local ChicaneIntegrity = require(script.Parent.Parent.Integrity.ChicaneIntegrity)
local MinimalProposer = require(script.Parent.MinimalProposer)
local JobRunner = require(script.Parent.JobRunner)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)

local TestPhase10 = {}

local function makeRequest(rawText, mechanic)
	return {
		request_id = "phase10-request",
		raw_text = rawText,
		parsed = {
			sector_id = 3,
			mechanic = mechanic,
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = {},
		timestamp = os.time(),
	}
end

local function makeState(mechanic, params)
	return {
		sector_id = 3,
		mechanic = mechanic,
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function makeMetrics(overrides)
	local metrics = {
		entry_speed = 40,
		exit_speed = 35,
		airborne = false,
		air_distance = 0,
		lateral_error = 0,
		vertical_displacement = 0,
		reacquired = true,
		airtime_distance = 0,
		lap_time = 25,
		slowdown_ratio = 1,
	}
	for key, value in pairs(overrides or {}) do
		metrics[key] = value
	end
	return metrics
end

local function makePacket(mechanic, params, hints, failureType, lastAction, metricsOverrides)
	return {
		request = makeRequest("phase10", mechanic),
		sector_state = makeState(mechanic, params),
		attempt_index = 0,
		last_action = lastAction,
		run_result = {
			success = false,
			failure = { type = failureType or "mechanic_integrity_failure", sector_id = 3 },
			metrics = makeMetrics(metricsOverrides),
		},
		diagnostics = { failure_sector = 3, hints = hints or {} },
		legal_actions = {
			numeric_levers = LevelMappings.NUMERIC_LEVERS[mechanic],
			pads = { "ingress", "egress" },
		},
	}
end

local function hintsContain(hints, needle)
	for _, hint in ipairs(hints) do
		if string.find(hint, needle, 1, true) then
			return true
		end
	end
	return false
end

local function waitForBaseline(): boolean
	local deadline = os.clock() + 45
	while os.clock() < deadline do
		if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
			return true
		end
		task.wait(0.25)
	end
	return false
end

local function waitForCommittedMechanic(sectorId: number, mechanic: string, timeoutSeconds: number)
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		local state = SectorRegistry.getCommitted(sectorId)
		if state ~= nil and state.mechanic == mechanic then
			return state
		end
		task.wait(0.1)
	end
	return SectorRegistry.getCommitted(sectorId)
end

local function waitForIdle(timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if JobRunner.isBusy() == false then
			return true
		end
		task.wait(0.1)
	end
	return JobRunner.isBusy() == false
end

local function summariseAttempts(job): string
	if not job or not job.attempts then
		return "no-attempts"
	end

	local parts = {}
	for index, attempt in ipairs(job.attempts) do
		local hints = attempt.hints or {}
		local hintText = if #hints > 0 then table.concat(hints, "&") else "none"
		table.insert(parts, string.format("%d:%s", index, hintText))
	end
	return table.concat(parts, " || ")
end

function TestPhase10.runUnit()
	local rampState = makeState("RampJump", {
		ramp_angle = 20,
		ramp_length = 12,
		gap_length = 1,
		landing_length = 12,
	})
	local rampPreflightOk, rampPreflightHints = RampJumpIntegrity.preflight(rampState)
	T.expect(
		"phase10_rampjump_preflight_gap_hint",
		rampPreflightOk == false and hintsContain(rampPreflightHints, "gap_length below minimum"),
		table.concat(rampPreflightHints, " | ")
	)

	local rampAirborneOk, rampAirborneHints = RampJumpIntegrity.evaluateRuntime(
		makeMetrics({ target_airborne = false, target_air_distance = 0, target_reacquired = true })
	)
	T.expect(
		"phase10_rampjump_runtime_airborne_hint",
		rampAirborneOk == false and hintsContain(rampAirborneHints, "never became airborne"),
		table.concat(rampAirborneHints, " | ")
	)

	local rampDistanceOk, rampDistanceHints = RampJumpIntegrity.evaluateRuntime(
		makeMetrics({ target_airborne = true, target_air_distance = 1, target_reacquired = true })
	)
	T.expect(
		"phase10_rampjump_runtime_air_distance_hint",
		rampDistanceOk == false and hintsContain(rampDistanceHints, "air distance too short"),
		table.concat(rampDistanceHints, " | ")
	)

	local rampReacquireOk, rampReacquireHints = RampJumpIntegrity.evaluateRuntime(
		makeMetrics({ target_airborne = true, target_air_distance = 8, target_reacquired = false })
	)
	T.expect(
		"phase10_rampjump_runtime_reacquire_hint",
		rampReacquireOk == false and hintsContain(rampReacquireHints, "reacquisition failed"),
		table.concat(rampReacquireHints, " | ")
	)

	local chicaneState = makeState("Chicane", {
		amplitude = 4,
		transition_length = 200,
		corridor_width = 14,
	})
	local chicanePreflightOk, chicanePreflightHints = ChicaneIntegrity.preflight(chicaneState)
	T.expect(
		"phase10_chicane_preflight_curvature_hint",
		chicanePreflightOk == false and hintsContain(chicanePreflightHints, "curvature"),
		table.concat(chicanePreflightHints, " | ")
	)

	local chicaneOverflowOk, chicaneOverflowHints = ChicaneIntegrity.preflight(makeState("Chicane", {
		amplitude = 8,
		transition_length = 30,
		corridor_width = 14,
	}))
	T.expect(
		"phase10_chicane_preflight_length_hint",
		chicaneOverflowOk == false and hintsContain(chicaneOverflowHints, "geometry exceeds sector length"),
		table.concat(chicaneOverflowHints, " | ")
	)

	local chicaneExcursionOk, chicaneExcursionHints = ChicaneIntegrity.evaluateRuntime(
		makeMetrics({
			target_left_offset = 1,
			target_right_offset = 5,
			target_lateral_band_changes = 2,
		})
	)
	T.expect(
		"phase10_chicane_runtime_excursion_hint",
		chicaneExcursionOk == false and hintsContain(chicaneExcursionHints, "runtime lateral excursion too small"),
		table.concat(chicaneExcursionHints, " | ")
	)

	local chicaneAlternationOk, chicaneAlternationHints = ChicaneIntegrity.evaluateRuntime(
		makeMetrics({
			target_left_offset = 5,
			target_right_offset = 5,
			target_lateral_band_changes = 1,
		})
	)
	T.expect(
		"phase10_chicane_runtime_alternation_hint",
		chicaneAlternationOk == false and hintsContain(chicaneAlternationHints, "runtime lateral alternation too small"),
		table.concat(chicaneAlternationHints, " | ")
	)

	local jumpTakeoffAction = MinimalProposer.repair(makePacket(
		"RampJump",
		{ ramp_angle = 20, ramp_length = 12, gap_length = 8, landing_length = 12 },
		{ "verifier never became airborne" }
	))
	T.expect(
		"phase10_proposer_jump_takeoff_picks_ingress_boost",
		jumpTakeoffAction ~= nil
			and jumpTakeoffAction.type == "SetPad"
			and jumpTakeoffAction.pad == "ingress"
			and jumpTakeoffAction.value == "Boost10",
		tostring(jumpTakeoffAction and jumpTakeoffAction.type == "SetPad" and jumpTakeoffAction.pad or jumpTakeoffAction and jumpTakeoffAction.lever)
	)

	local jumpTakeoffFollowupAction = MinimalProposer.repair(makePacket(
		"RampJump",
		{ ramp_angle = 20, ramp_length = 12, gap_length = 8, landing_length = 12 },
		{ "verifier never became airborne" },
		"mechanic_integrity_failure",
		{ type = "SetPad", pad = "ingress", value = "Boost10" }
	))
	T.expect(
		"phase10_proposer_jump_takeoff_steepens_after_boost",
		jumpTakeoffFollowupAction ~= nil
			and (
				(jumpTakeoffFollowupAction.type == "SetNumericLever" and jumpTakeoffFollowupAction.lever == "ramp_angle" and jumpTakeoffFollowupAction.value > 20)
				or (jumpTakeoffFollowupAction.type == "SetNumericLever" and jumpTakeoffFollowupAction.lever == "ramp_length" and jumpTakeoffFollowupAction.value > 12)
				or (jumpTakeoffFollowupAction.type == "SetNumericLever" and jumpTakeoffFollowupAction.lever == "gap_length" and jumpTakeoffFollowupAction.value < 8)
			),
		tostring(jumpTakeoffFollowupAction and jumpTakeoffFollowupAction.type == "SetNumericLever" and jumpTakeoffFollowupAction.lever .. "=" .. tostring(jumpTakeoffFollowupAction.value) or jumpTakeoffFollowupAction and jumpTakeoffFollowupAction.type)
	)

	local jumpLandingAction = MinimalProposer.repair(makePacket(
		"RampJump",
		{ ramp_angle = 25, ramp_length = 12, gap_length = 8, landing_length = 8 },
		{ "semi-rail reacquisition failed after landing" }
	))
	T.expect(
		"phase10_proposer_jump_landing_softens_exit",
		jumpLandingAction ~= nil
			and (
				(jumpLandingAction.type == "SetPad"
					and jumpLandingAction.pad == "egress"
					and string.find(jumpLandingAction.value, "Brake", 1, true) ~= nil)
				or (jumpLandingAction.type == "SetNumericLever"
					and (jumpLandingAction.lever == "ramp_angle"
						or jumpLandingAction.lever == "gap_length"
						or jumpLandingAction.lever == "landing_length"))
			),
		tostring(jumpLandingAction and jumpLandingAction.type == "SetPad" and jumpLandingAction.pad or jumpLandingAction and jumpLandingAction.lever)
	)

	local chicaneInstabilityAction = MinimalProposer.repair(makePacket(
		"Chicane",
		{ amplitude = 8, transition_length = 15, corridor_width = 14 },
		{ "entry unstable" }
	))
	T.expect(
		"phase10_proposer_chicane_instability_picks_brake_before_geometry",
		chicaneInstabilityAction ~= nil
			and chicaneInstabilityAction.type == "SetPad"
			and chicaneInstabilityAction.pad == "ingress"
			and string.find(chicaneInstabilityAction.value, "Brake", 1, true) ~= nil,
		tostring(chicaneInstabilityAction and chicaneInstabilityAction.type == "SetPad" and chicaneInstabilityAction.pad or chicaneInstabilityAction and chicaneInstabilityAction.lever)
	)

	local crestStallBoostAction = MinimalProposer.repair(makePacket(
		"CrestDip",
		{ height_or_depth = 10, radius = 20, sector_length = 24 },
		{},
		"local_execution_failure"
	))
	T.expect(
		"phase10_proposer_crestdip_stall_picks_ingress_boost_first",
		crestStallBoostAction ~= nil
			and crestStallBoostAction.type == "SetPad"
			and crestStallBoostAction.pad == "ingress"
			and crestStallBoostAction.value == "Boost10",
		tostring(crestStallBoostAction and crestStallBoostAction.type == "SetPad" and crestStallBoostAction.pad or crestStallBoostAction and crestStallBoostAction.lever)
	)

	local crestStallFollowupAction = MinimalProposer.repair({
		request = makeRequest("phase10", "CrestDip"),
		sector_state = makeState("CrestDip", { height_or_depth = 10, radius = 20, sector_length = 24 }),
		attempt_index = 3,
		last_action = { type = "SetPad", pad = "ingress", value = "Boost10" },
		run_result = {
			success = false,
			failure = { type = "local_execution_failure", sector_id = 3 },
			metrics = makeMetrics(),
		},
		diagnostics = { failure_sector = 3, hints = {} },
		legal_actions = {
			numeric_levers = LevelMappings.NUMERIC_LEVERS.CrestDip,
			pads = { "ingress", "egress" },
		},
	})
	T.expect(
		"phase10_proposer_crestdip_stall_followup_softens_more_aggressively",
		crestStallFollowupAction ~= nil
			and crestStallFollowupAction.type == "SetNumericLever"
			and (
				(crestStallFollowupAction.lever == "sector_length" and crestStallFollowupAction.value >= 40)
				or (crestStallFollowupAction.lever == "height_or_depth" and crestStallFollowupAction.value <= 7)
			),
		tostring(crestStallFollowupAction and crestStallFollowupAction.type == "SetNumericLever" and crestStallFollowupAction.lever .. "=" .. tostring(crestStallFollowupAction.value) or crestStallFollowupAction and crestStallFollowupAction.type)
	)

	local jumpDownstreamAction = MinimalProposer.repair(makePacket(
		"RampJump",
		{ ramp_angle = 20, ramp_length = 12, gap_length = 8, landing_length = 12 },
		{},
		"downstream_failure"
	))
	T.expect(
		"phase10_proposer_jump_downstream_softens_landing",
		jumpDownstreamAction ~= nil
			and (jumpDownstreamAction.type == "SetNumericLever"
				and (jumpDownstreamAction.lever == "ramp_angle"
					or jumpDownstreamAction.lever == "gap_length"
					or jumpDownstreamAction.lever == "landing_length")),
		tostring(jumpDownstreamAction and jumpDownstreamAction.type == "SetPad" and jumpDownstreamAction.pad or jumpDownstreamAction and jumpDownstreamAction.lever)
	)

	local jumpShortAction = MinimalProposer.repair(makePacket(
		"RampJump",
		{ ramp_angle = 20, ramp_length = 12, gap_length = 8, landing_length = 12 },
		{ "air distance too short" }
	))
	T.expect(
		"phase10_proposer_jump_shortfall_does_not_raise_gap",
		jumpShortAction ~= nil
			and not (
				jumpShortAction.type == "SetNumericLever"
				and (
					(jumpShortAction.lever == "gap_length" and jumpShortAction.value > 8)
					or (jumpShortAction.lever == "ramp_angle" and jumpShortAction.value > 20)
				)
			),
		tostring(jumpShortAction and jumpShortAction.type == "SetNumericLever" and jumpShortAction.lever .. "=" .. tostring(jumpShortAction.value) or jumpShortAction and jumpShortAction.type)
	)
end

function TestPhase10.runIntegration()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase10_integration_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase10_baseline_ready", "baseline lap did not complete before integration tests")
		return
	end

	local okJump, jumpReason = JobRunner.submit("add a really gentle short jump in sector 3")
	local jumpJob = JobRunner.getLastJob()
	local jumpState = waitForCommittedMechanic(3, "RampJump", 2)
	T.expect(
		"phase10_jump_commits_after_repair_chain",
		okJump == true
			and jumpReason == nil
			and jumpJob ~= nil
			and jumpJob.final_status == "committed"
			and #jumpJob.attempts >= 2
			and jumpState ~= nil
			and jumpState.mechanic == "RampJump",
		string.format(
			"final_status=%s attempts=%d mechanic=%s hints=%s",
			tostring(jumpJob and jumpJob.final_status),
			jumpJob and #jumpJob.attempts or -1,
			tostring(jumpState and jumpState.mechanic),
			summariseAttempts(jumpJob)
		)
	)

	task.wait(Constants.UI_SUCCESS_DWELL + 0.25)
	local idle = waitForIdle(5)

	-- Phase 11 capped amplitude at TRACK_WIDTH/2=8; tight bias (amplitude+4) from
	-- default(5) reaches 9 → clamped to 8. The initial proposal now passes
	-- preflight and runtime on the first attempt, so repair chain is no longer
	-- required. The assertion relaxed from >= 2 to >= 1.
	local okChicane, chicaneReason = JobRunner.submit("add a tight chicane in sector 8")
	local chicaneJob = JobRunner.getLastJob()
	local chicaneState = waitForCommittedMechanic(8, "Chicane", 2)
	T.expect(
		"phase10_chicane_commits_after_repair_chain",
		okChicane == true
			and chicaneReason == nil
			and idle
			and chicaneJob ~= nil
			and chicaneJob.final_status == "committed"
			and #chicaneJob.attempts >= 1
			and chicaneState ~= nil
			and chicaneState.mechanic == "Chicane",
		string.format(
			"idle=%s ok=%s reason=%s final_status=%s attempts=%d mechanic=%s hints=%s",
			tostring(idle),
			tostring(okChicane),
			tostring(chicaneReason),
			tostring(chicaneJob and chicaneJob.final_status),
			chicaneJob and #chicaneJob.attempts or -1,
			tostring(chicaneState and chicaneState.mechanic),
			summariseAttempts(chicaneJob)
		)
	)
end

function TestPhase10.run()
	TestPhase10.runUnit()
	TestPhase10.runIntegration()
end

return TestPhase10
