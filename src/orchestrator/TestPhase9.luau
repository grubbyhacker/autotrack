-- TestPhase9.luau
-- Verifies Phase 9 deliverables: CrestDipPath, airtime tracking, curvature gate,
-- and the multi-step repair story that ends in commit (or revert for impossible qualifiers).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local T = require(script.Parent.TestUtils)
local CrestDipPath = require(game.ServerScriptService:WaitForChild("AutoTrackCore"):WaitForChild("Mechanics"):WaitForChild("CrestDipPath"))
local CrestDipIntegrity = require(script.Parent.Parent.Integrity.CrestDipIntegrity)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local MinimalProposer = require(script.Parent.MinimalProposer)
local JobRunner = require(script.Parent.JobRunner)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)

local TestPhase9 = {}

local function makeRequest(rawText)
	return {
		request_id = "phase9-request",
		raw_text = rawText,
		parsed = {
			sector_id = 3,
			mechanic = "CrestDip",
			request_kind = "Mechanic",
			pad_side = nil,
			pad_value = nil,
		},
		qualifiers = {},
		timestamp = os.time(),
	}
end

local function makeState(params)
	return {
		sector_id = 3,
		mechanic = "CrestDip",
		params = params,
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
end

local function makeMetrics(overrides)
	local m = {
		entry_speed = 40,
		exit_speed = 35,
		airborne = false,
		air_distance = 0,
		lateral_error = 0,
		vertical_displacement = 10,
		reacquired = true,
		airtime_distance = 0,
		lap_time = 25,
		slowdown_ratio = 1,
	}
	for key, value in pairs(overrides or {}) do
		m[key] = value
	end
	return m
end

local function makePacket(params, hints, failureType, lastAction, metricsOverrides)
	return {
		request = makeRequest("phase9"),
		sector_state = makeState(params),
		attempt_index = 0,
		last_action = lastAction,
		run_result = {
			success = false,
			failure = { type = failureType or "mechanic_integrity_failure", sector_id = 3 },
			metrics = makeMetrics(metricsOverrides),
		},
		diagnostics = { failure_sector = 3, hints = hints or {} },
		legal_actions = {
			numeric_levers = LevelMappings.NUMERIC_LEVERS.CrestDip,
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

function TestPhase9.runUnit()
	local points = CrestDipPath.buildLocalCenterlinePoints(6, 40)
	local maxY = -math.huge
	for _, point in ipairs(points) do
		if point.Y > maxY then
			maxY = point.Y
		end
	end
	local expectedStartZ = (Constants.STRAIGHT_LENGTH - 40) * 0.5
	T.expect(
		"phase9_path_waypoints_follow_cosine",
		#points >= CrestDipPath.CURVE_SEGMENTS + 2
			and math.abs(points[1].Y) < 1e-4
			and math.abs(points[#points].Y) < 1e-4
			and math.abs(maxY - 6) < 1e-3
			and math.abs(points[2].Z - expectedStartZ) < 0.01
			and math.abs(points[#points - 1].Z - (Constants.STRAIGHT_LENGTH - expectedStartZ)) < 0.01,
		string.format("maxY=%.4f startZ=%.4f endZ=%.4f", maxY, points[2].Z, points[#points - 1].Z)
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
	T.expect(
		"phase9_trackgenerator_routes_crestdip",
		sawElevated,
		"no elevated waypoint found for CrestDip override"
	)

	local preflightOk, preflightHints = CrestDipIntegrity.preflight(
		makeState({ height_or_depth = 6, radius = 20, sector_length = 40 })
	)
	T.expect(
		"phase9_preflight_curvature_hint",
		preflightOk == false and hintsContain(preflightHints, "curvature"),
		table.concat(preflightHints, " | ")
	)

	local runtimeOk, runtimeHints = CrestDipIntegrity.evaluateRuntime(
		makeMetrics({ target_vertical_displacement = 2, target_reacquired = true })
	)
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
		tostring(airtimeAction and airtimeAction.lever) .. "=" .. tostring(airtimeAction and airtimeAction.value)
	)

	local curvaturePacket = makePacket(
		{ height_or_depth = 6, radius = 20, sector_length = 40 },
		{ "crest curvature too gentle" }
	)
	local curvatureAction = MinimalProposer.repair(curvaturePacket)
	T.expect(
		"phase9_proposer_curvature_picks_height_increase",
		curvatureAction ~= nil
			and curvatureAction.type == "SetNumericLever"
			and curvatureAction.lever == "height_or_depth"
			and curvatureAction.value > 6,
		tostring(curvatureAction and curvatureAction.lever) .. "=" .. tostring(curvatureAction and curvatureAction.value)
	)

	local dedupPacket = makePacket(
		{ height_or_depth = 6, radius = 20, sector_length = 40 },
		{ "crest curvature too gentle" },
		"mechanic_integrity_failure",
		{ type = "SetNumericLever", lever = "height_or_depth", value = 8 }
	)
	local dedupAction = MinimalProposer.repair(dedupPacket)
	T.expect(
		"phase9_proposer_dedup",
		dedupAction ~= nil
			and not (dedupAction.type == "SetNumericLever"
				and dedupAction.lever == "height_or_depth"
				and dedupAction.value == 8),
		tostring(dedupAction and dedupAction.lever) .. "=" .. tostring(dedupAction and dedupAction.value)
	)

	local crestPadPacket = makePacket(
		{ height_or_depth = 10, radius = 20, sector_length = 24 },
		{},
		"local_execution_failure"
	)
	local crestPadAction = MinimalProposer.repair(crestPadPacket)
	T.expect(
		"phase9_proposer_crestdip_local_failure_lengthens_feature_first",
		crestPadAction ~= nil
			and crestPadAction.type == "SetNumericLever"
			and crestPadAction.lever == "sector_length"
			and crestPadAction.value > 24,
		tostring(crestPadAction and crestPadAction.type == "SetNumericLever" and crestPadAction.lever or crestPadAction and crestPadAction.type)
	)

	local crestExitPadPacket = makePacket(
		{ height_or_depth = 8, radius = 20, sector_length = 30 },
		{ "car did not reacquire semi-rail before sector exit" }
	)
	local crestExitPadAction = MinimalProposer.repair(crestExitPadPacket)
	T.expect(
		"phase9_proposer_crestdip_reacquire_picks_egress_brake",
		crestExitPadAction ~= nil
			and crestExitPadAction.type == "SetPad"
			and crestExitPadAction.pad == "egress"
			and crestExitPadAction.value == "Brake",
		tostring(crestExitPadAction and crestExitPadAction.type == "SetPad" and crestExitPadAction.pad or crestExitPadAction and crestExitPadAction.type)
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
				if string.find(hint, "curvature", 1, true) then sawCurvatureHint = true end
				if string.find(hint, "airborne too long", 1, true) then sawAirtimeHint = true end
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
	T.expect(
		"phase9_crest_reverts_on_impossible_qualifiers",
		okImpossible == true
			and impossibleReason == nil
			and impossibleJob ~= nil
			and impossibleJob.final_status == "reverted"
			and #impossibleJob.attempts == Constants.MAX_REPAIR_ATTEMPTS + 1,
		string.format(
			"final_status=%s attempts=%d",
			tostring(impossibleJob and impossibleJob.final_status),
			impossibleJob and #impossibleJob.attempts or -1
		)
	)
end

function TestPhase9.run()
	TestPhase9.runUnit()
	TestPhase9.runIntegration()
end

return TestPhase9
