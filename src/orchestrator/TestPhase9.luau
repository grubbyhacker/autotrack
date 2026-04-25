--!strict

-- TestPhase9.luau
-- Verifies Phase 9 deliverables: CrestDipPath, airtime tracking, curvature gate,
-- and the multi-step repair story that ends in commit (or revert for impossible qualifiers).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ContractBuilders = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("ContractBuilders"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local CrestDipPath = require(
	game.ServerScriptService:WaitForChild("AutoTrackCore"):WaitForChild("Mechanics"):WaitForChild("CrestDipPath")
)
local CrestDipTuner = require(
	game.ServerScriptService:WaitForChild("AutoTrackCore"):WaitForChild("Mechanics"):WaitForChild("CrestDipTuner")
)
local CrestDipIntegrity = require(script.Parent.Parent.Integrity.CrestDipIntegrity)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local MinimalProposer = require(script.Parent.MinimalProposer)
local JobRunner = require(script.Parent.JobRunner)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)

local TestPhase9 = {}

type AgentAction = Types.AgentAction
type FailurePacket = Types.FailurePacket
type FailureType = Types.FailureType
type Request = Types.Request
type RunResult = Types.RunResult
type RunMetrics = Types.RunMetrics
type SectorParams = Types.SectorParams
type SectorState = Types.SectorState

type MetricsOverrides = {
	entry_speed: number?,
	exit_speed: number?,
	airborne: boolean?,
	air_distance: number?,
	lateral_error: number?,
	vertical_displacement: number?,
	reacquired: boolean?,
	airtime_distance: number?,
	target_airborne: boolean?,
	target_air_distance: number?,
	target_vertical_displacement: number?,
	target_reacquired: boolean?,
	target_airtime_distance: number?,
	target_left_offset: number?,
	target_right_offset: number?,
	target_lateral_band_changes: number?,
	target_entered: boolean?,
	target_exited: boolean?,
	target_progress: number?,
	target_reacquire_distance: number?,
	target_reacquire_lateral_offset: number?,
	target_peak_body_distance: number?,
	target_exit_angular_speed: number?,
	target_exit_vertical_speed: number?,
	target_touchdown_up_dot: number?,
	target_touchdown_down_speed: number?,
	target_min_speed: number?,
	target_apex_min_speed: number?,
	lap_time: number?,
	slowdown_ratio: number?,
}

local function makeRequest(rawText: string): Request
	return ContractBuilders.playerMechanicRequest("phase9-request", rawText, 3, "CrestDip", {}, os.time())
end

local function makeState(params: SectorParams): SectorState
	return {
		sector_id = 3,
		mechanic = "CrestDip",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function makeMetrics(overrides: MetricsOverrides?): RunMetrics
	local source: MetricsOverrides = if overrides ~= nil then overrides else {}
	return {
		entry_speed = source.entry_speed or 40,
		exit_speed = source.exit_speed or 35,
		airborne = if source.airborne ~= nil then source.airborne else false,
		air_distance = source.air_distance or 0,
		lateral_error = source.lateral_error or 0,
		vertical_displacement = source.vertical_displacement or 10,
		reacquired = if source.reacquired ~= nil then source.reacquired else true,
		airtime_distance = source.airtime_distance or 0,
		target_airborne = source.target_airborne,
		target_air_distance = source.target_air_distance,
		target_vertical_displacement = source.target_vertical_displacement,
		target_reacquired = source.target_reacquired,
		target_airtime_distance = source.target_airtime_distance,
		target_left_offset = source.target_left_offset,
		target_right_offset = source.target_right_offset,
		target_lateral_band_changes = source.target_lateral_band_changes,
		target_entered = source.target_entered,
		target_exited = source.target_exited,
		target_progress = source.target_progress,
		target_reacquire_distance = source.target_reacquire_distance,
		target_reacquire_lateral_offset = source.target_reacquire_lateral_offset,
		target_peak_body_distance = source.target_peak_body_distance,
		target_exit_angular_speed = source.target_exit_angular_speed,
		target_exit_vertical_speed = source.target_exit_vertical_speed,
		target_touchdown_up_dot = source.target_touchdown_up_dot,
		target_touchdown_down_speed = source.target_touchdown_down_speed,
		target_min_speed = source.target_min_speed,
		target_apex_min_speed = source.target_apex_min_speed or 0,
		lap_time = source.lap_time or 25,
		slowdown_ratio = source.slowdown_ratio or 1,
	}
end

local function makePacket(
	params: SectorParams,
	hints: { string }?,
	failureType: FailureType?,
	lastAction: AgentAction?,
	metricsOverrides: MetricsOverrides?,
	failureDetail: string?
): FailurePacket
	local metrics = makeMetrics(metricsOverrides)
	local effectiveFailureType: FailureType = failureType or "mechanic_integrity_failure"
	local runResult: RunResult = {
		success = false,
		failure = { type = effectiveFailureType, sector_id = 3, detail = failureDetail },
		metrics = metrics,
		failure_position = nil,
		final_position = nil,
		trajectory_tail = nil,
		score = nil,
	}
	return {
		request = makeRequest("phase9"),
		sector_state = makeState(params),
		attempt_index = 0,
		last_action = lastAction,
		run_result = runResult,
		diagnostics = {
			failure_sector = 3,
			hints = hints or {},
			failure_type = effectiveFailureType,
			failure_detail = failureDetail,
			target_entry_speed = metrics.entry_speed,
			target_exit_speed = metrics.exit_speed,
			target_reacquired = metrics.target_reacquired,
			target_airtime_distance = metrics.target_airtime_distance,
			target_apex_min_speed = metrics.target_apex_min_speed,
			downstream_sector_state = nil,
		},
		legal_actions = {
			numeric_levers = LevelMappings.NUMERIC_LEVERS.CrestDip,
			pads = { "ingress", "egress" },
		},
		design_intent = nil,
		memory_context = nil,
	}
end

local function hintsContain(hints: { string }, needle: string): boolean
	for _, hint in ipairs(hints) do
		if string.find(hint, needle, 1, true) then
			return true
		end
	end
	return false
end

local function actionSummary(action: AgentAction?): string
	if action == nil then
		return "nil"
	end
	if action.type == "SetNumericLever" then
		return action.lever .. "=" .. tostring(action.value)
	end
	return action.pad .. "=" .. action.value
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

function TestPhase9.runUnit()
	local points = CrestDipPath.buildLocalCenterlinePoints(6, 40)
	local maxY = -math.huge
	local sawStartOffset = false
	local sawCurveEnd = false
	for _, point in ipairs(points) do
		if point.Y > maxY then
			maxY = point.Y
		end
		if math.abs(point.Z - ((Constants.STRAIGHT_LENGTH - 40) * 0.5)) < 0.01 then
			sawStartOffset = true
		end
		if math.abs(point.Z - (Constants.STRAIGHT_LENGTH - ((Constants.STRAIGHT_LENGTH - 40) * 0.5))) < 0.01 then
			sawCurveEnd = true
		end
	end
	local expectedStartZ = (Constants.STRAIGHT_LENGTH - 40) * 0.5
	T.expect(
		"phase9_path_waypoints_follow_cosine",
		#points > CrestDipPath.CURVE_SEGMENTS + 2
			and math.abs(points[1].Y) < 1e-4
			and math.abs(points[#points].Y) < 1e-4
			and math.abs(points[2].Y) < 1e-4
			and math.abs(maxY - 6) < 1e-3
			and sawStartOffset
			and sawCurveEnd
			and math.abs(points[#points].Z - Constants.STRAIGHT_LENGTH) < 0.01,
		string.format("maxY=%.4f startZ=%.4f finalZ=%.4f", maxY, expectedStartZ, points[#points].Z)
	)

	local tunedHeight, tunedLength = CrestDipTuner.tune(10, 20)
	T.expect(
		"phase9_tuner_preserves_runout_and_curvature",
		tunedHeight >= Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT
			and tunedLength >= 20
			and CrestDipTuner.runout(tunedLength) >= 20
			and CrestDipTuner.peakSlope(tunedHeight, tunedLength) <= 0.70
			and math.abs(tunedHeight) / (tunedLength * tunedLength) >= Constants.CRESTDIP_MIN_CURVATURE,
		string.format(
			"h=%d L=%d runout=%.2f slope=%.3f",
			tunedHeight,
			tunedLength,
			CrestDipTuner.runout(tunedLength),
			CrestDipTuner.peakSlope(tunedHeight, tunedLength)
		)
	)

	local softenedHeight, softenedLength = CrestDipTuner.tune(4, 35, {
		maxHeight = 5,
		minLength = 31,
	})
	T.expect(
		"phase9_tuner_softening_stays_monotonic",
		softenedHeight <= 5
			and softenedLength >= 31
			and CrestDipTuner.runout(softenedLength) >= 20
			and math.abs(softenedHeight) / (softenedLength * softenedLength) >= Constants.CRESTDIP_MIN_CURVATURE,
		string.format("h=%d L=%d", softenedHeight, softenedLength)
	)

	local sharpenedHeight, sharpenedLength = CrestDipTuner.tune(8, 28, {
		minHeight = 6,
		maxLength = 30,
	})
	T.expect(
		"phase9_tuner_sharpening_stays_monotonic",
		(sharpenedHeight >= 6 or sharpenedLength <= 30)
			and CrestDipTuner.peakSlope(sharpenedHeight, sharpenedLength) <= 0.70
			and math.abs(sharpenedHeight) / (sharpenedLength * sharpenedLength) >= Constants.CRESTDIP_MIN_CURVATURE,
		string.format("h=%d L=%d", sharpenedHeight, sharpenedLength)
	)

	local sectors = TrackGenerator.generate()
	local waypoints = TrackGenerator.getLapPath(sectors, {
		[3] = makeState({ height_or_depth = 8, radius = 20, sector_length = 40 }),
	})
	local sawElevated = false
	for _, cf in ipairs(waypoints) do
		if cf.Position.Y > Constants.TRACK_THICKNESS + Constants.CAR_HEIGHT * 0.5 + 1 then
			sawElevated = true
			break
		end
	end
	T.expect("phase9_trackgenerator_routes_crestdip", sawElevated, "no elevated waypoint found for CrestDip override")

	local preflightOk, preflightHints =
		CrestDipIntegrity.preflight(makeState({ height_or_depth = 6, radius = 20, sector_length = 40 }))
	T.expect(
		"phase9_preflight_curvature_hint",
		preflightOk == false and hintsContain(preflightHints, "curvature"),
		table.concat(preflightHints, " | ")
	)

	local runtimeOk, runtimeHints =
		CrestDipIntegrity.evaluateRuntime(makeMetrics({ target_vertical_displacement = 2, target_reacquired = true }))
	T.expect(
		"phase9_runtime_vertical_hint",
		runtimeOk == false and hintsContain(runtimeHints, "runtime vertical displacement too small"),
		table.concat(runtimeHints, " | ")
	)

	local curvatureOk, curvatureHints = CrestDipIntegrity.evaluate(
		makeState({ height_or_depth = 6, radius = 20, sector_length = 40 }),
		makeMetrics({ vertical_displacement = 6 })
	)
	T.expect(
		"phase9_curvature_hint",
		curvatureOk == false and hintsContain(curvatureHints, "curvature"),
		table.concat(curvatureHints, " | ")
	)

	local airtimeOk, airtimeHints = CrestDipIntegrity.evaluate(
		makeState({ height_or_depth = 8, radius = 20, sector_length = 30 }),
		makeMetrics({
			vertical_displacement = 8,
			airborne = true,
			airtime_distance = 40,
			target_vertical_displacement = 8,
			target_airborne = true,
			target_airtime_distance = 40,
		})
	)
	T.expect(
		"phase9_airtime_hint",
		airtimeOk == false and hintsContain(airtimeHints, "airborne too long"),
		table.concat(airtimeHints, " | ")
	)

	local apexSpeedOk, apexSpeedHints = CrestDipIntegrity.evaluate(
		makeState({ height_or_depth = 8, radius = 20, sector_length = 30 }),
		makeMetrics({
			vertical_displacement = 8,
			target_vertical_displacement = 8,
			target_reacquired = true,
			target_apex_min_speed = Constants.CRESTDIP_APEX_MIN_SPEED - 2,
		})
	)
	T.expect(
		"phase9_apex_speed_hint",
		apexSpeedOk == false and hintsContain(apexSpeedHints, "apex speed too low"),
		table.concat(apexSpeedHints, " | ")
	)

	local airtimePacket = makePacket(
		{ height_or_depth = 8, radius = 20, sector_length = 30 },
		{ "airborne too long after liftoff" },
		"mechanic_integrity_failure",
		nil,
		{ airborne = true, airtime_distance = 40, target_airborne = true, target_airtime_distance = 40 }
	)
	local airtimeAction = MinimalProposer.repair(airtimePacket)
	T.expect(
		"phase9_proposer_airtime_picks_height_reduction",
		airtimeAction ~= nil
			and airtimeAction.type == "SetNumericLever"
			and airtimeAction.lever == "height_or_depth"
			and airtimeAction.value < 8,
		actionSummary(airtimeAction)
	)

	local curvaturePacket = makePacket(
		{ height_or_depth = 6, radius = 20, sector_length = 40 },
		{ "crest curvature too gentle" }
	)
	local curvatureAction = MinimalProposer.repair(curvaturePacket)
	T.expect(
		"phase9_proposer_curvature_picks_sharpening_change",
		curvatureAction ~= nil
			and curvatureAction.type == "SetNumericLever"
			and (
				(curvatureAction.lever == "height_or_depth" and curvatureAction.value > 6)
				or (curvatureAction.lever == "sector_length" and curvatureAction.value < 40)
			),
		actionSummary(curvatureAction)
	)

	local dedupPacket = makePacket(
		{ height_or_depth = 6, radius = 20, sector_length = 40 },
		{ "crest curvature too gentle" },
		"mechanic_integrity_failure",
		ContractBuilders.setNumericLever("height_or_depth", 8)
	)
	local dedupAction = MinimalProposer.repair(dedupPacket)
	T.expect(
		"phase9_proposer_dedup",
		dedupAction ~= nil
			and not (
				dedupAction.type == "SetNumericLever"
				and dedupAction.lever == "height_or_depth"
				and dedupAction.value == 8
			),
		actionSummary(dedupAction)
	)

	local crestRequest, crestRequestErr = RequestParser.parse("add a crest in sector 3", "phase9-crest-initial")
	assert(crestRequest ~= nil, "expected crest request: " .. tostring(crestRequestErr))
	local initialCrestState, initialCrestErr = MinimalProposer.initial(crestRequest)
	T.expect(
		"phase9_initial_crestdip_plain_request_uses_strong_ingress_brake",
		initialCrestErr == nil
			and initialCrestState ~= nil
			and initialCrestState.pads.ingress == "Brake25"
			and initialCrestState.pads.egress == "None",
		tostring(initialCrestErr or initialCrestState and initialCrestState.pads.ingress or "nil")
	)

	local crestPadPacket = makePacket(
		{ height_or_depth = 10, radius = 20, sector_length = 24 },
		{},
		"local_execution_failure",
		nil,
		nil,
		"no_progress"
	)
	local crestPadAction = MinimalProposer.repair(crestPadPacket)
	T.expect(
		"phase9_proposer_crestdip_local_failure_boosts_first",
		crestPadAction ~= nil
			and crestPadAction.type == "SetPad"
			and crestPadAction.pad == "ingress"
			and string.find(crestPadAction.value, "Boost", 1, true) ~= nil,
		tostring(
			crestPadAction and crestPadAction.type == "SetPad" and crestPadAction.pad
				or crestPadAction and crestPadAction.type
		)
	)

	local crestCrashPacket = makePacket(
		{ height_or_depth = 10, radius = 20, sector_length = 24 },
		{},
		"local_execution_failure",
		nil,
		{ target_progress = 0.2 },
		"spinout"
	)
	local crestCrashAction = MinimalProposer.repair(crestCrashPacket)
	T.expect(
		"phase9_proposer_crestdip_spinout_brakes_first",
		crestCrashAction ~= nil
			and crestCrashAction.type == "SetPad"
			and crestCrashAction.pad == "ingress"
			and string.find(crestCrashAction.value, "Brake", 1, true) ~= nil,
		tostring(
			crestCrashAction and crestCrashAction.type == "SetPad" and crestCrashAction.pad
				or crestCrashAction and crestCrashAction.type
		)
	)

	local crestOffTrackPacket = makePacket(
		{ height_or_depth = 10, radius = 20, sector_length = 24 },
		{},
		"local_execution_failure",
		nil,
		{ target_progress = 0.2 },
		"off_track"
	)
	local crestOffTrackAction = MinimalProposer.repair(crestOffTrackPacket)
	T.expect(
		"phase9_proposer_crestdip_off_track_brakes_first",
		crestOffTrackAction ~= nil
			and crestOffTrackAction.type == "SetPad"
			and crestOffTrackAction.pad == "ingress"
			and string.find(crestOffTrackAction.value, "Brake", 1, true) ~= nil,
		tostring(
			crestOffTrackAction and crestOffTrackAction.type == "SetPad" and crestOffTrackAction.pad
				or crestOffTrackAction and crestOffTrackAction.type
		)
	)

	local crestExitPadPacket = makePacket(
		{ height_or_depth = 8, radius = 20, sector_length = 30 },
		{ "car did not reacquire semi-rail before sector exit" }
	)
	local crestExitPadAction = MinimalProposer.repair(crestExitPadPacket)
	T.expect(
		"phase9_proposer_crestdip_reacquire_picks_ingress_brake",
		crestExitPadAction ~= nil
			and crestExitPadAction.type == "SetPad"
			and crestExitPadAction.pad == "ingress"
			and string.find(crestExitPadAction.value, "Brake", 1, true) ~= nil,
		tostring(
			crestExitPadAction and crestExitPadAction.type == "SetPad" and crestExitPadAction.pad
				or crestExitPadAction and crestExitPadAction.type
		)
	)
end

function TestPhase9.runIntegration()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase9_integration_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase9_baseline_ready", "baseline lap did not complete before integration tests")
		return
	end

	local okCrest, crestReason = JobRunner.submit("add a crest in sector 3")
	local crestJob = JobRunner.getLastJob()
	local crestState = SectorRegistry.getCommitted(3)
	local sawCurvatureHint = false
	local sawAirtimeHint = false
	local attemptsCount = crestJob and #crestJob.attempts or 0
	if crestJob then
		for _, attempt in ipairs(crestJob.attempts) do
			for _, hint in ipairs(attempt.hints or {}) do
				if string.find(hint, "curvature", 1, true) then
					sawCurvatureHint = true
				end
				if string.find(hint, "airborne too long", 1, true) then
					sawAirtimeHint = true
				end
			end
		end
	end
	T.expect(
		"phase9_crest_commits_after_repair_chain",
		okCrest == true
			and crestReason == nil
			and crestJob ~= nil
			and crestJob.final_status == "committed"
			and attemptsCount >= 2
			and crestState ~= nil
			and crestState.mechanic == "CrestDip",
		string.format(
			"final_status=%s attempts=%d curvature=%s airtime=%s",
			tostring(crestJob and crestJob.final_status),
			attemptsCount,
			tostring(sawCurvatureHint),
			tostring(sawAirtimeHint)
		)
	)

	local okImpossible, impossibleReason = JobRunner.submit("add a really tall steep short crest in sector 3")
	local impossibleJob = JobRunner.getLastJob()
	local impossibleState = SectorRegistry.getCommitted(3)
	T.expect(
		"phase9_crest_extreme_request_reaches_terminal_state",
		okImpossible == true
			and impossibleReason == nil
			and impossibleJob ~= nil
			and (impossibleJob.final_status == "reverted" or impossibleJob.final_status == "committed")
			and #impossibleJob.attempts <= Constants.MAX_REPAIR_ATTEMPTS + 1
			and impossibleState ~= nil
			and impossibleState.mechanic == "CrestDip",
		string.format(
			"final_status=%s attempts=%d mechanic=%s",
			tostring(impossibleJob and impossibleJob.final_status),
			impossibleJob and #impossibleJob.attempts or -1,
			tostring(impossibleState and impossibleState.mechanic)
		)
	)
end

function TestPhase9.run()
	TestPhase9.runUnit()
	TestPhase9.runIntegration()
end

return TestPhase9
