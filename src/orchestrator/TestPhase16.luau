local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local T = require(script.Parent.TestUtils)
local TestSession = require(script.Parent.TestSession)
local RequestParser = require(script.Parent.Parent.Agent.RequestParser)
local LLMAdapter = require(script.Parent.Parent.Agent.LLMAdapter)
local MinimalProposer = require(script.Parent.MinimalProposer)
local AttemptRunner = require(script.Parent.AttemptRunner)
local RuntimeContext = require(script.Parent.RuntimeContext)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local RampJumpPath = require(script.Parent.Parent.Mechanics.RampJumpPath)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local CameraDemo = require(script.Parent.CameraDemo)

type SectorState = Types.SectorState

local TestPhase16 = {}
local EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }

local function makeState(sectorId: number, params, ingress: string?, egress: string?): SectorState
	return {
		sector_id = sectorId,
		mechanic = "RampJump",
		params = params,
		pads = {
			ingress = ingress or "None",
			egress = egress or "None",
		},
		version = 0,
	}
end

local function makeRequest(rawText: string)
	local request, err = RequestParser.parse(rawText, "phase16-req")
	assert(request ~= nil, "request parse failed: " .. tostring(err))
	return request
end

local function getSectorMeta(sectorId: number)
	local sectors = TrackGenerator.generate()
	for _, sector in ipairs(sectors) do
		if sector.id == sectorId then
			return sector
		end
	end
	error("sector not found: " .. tostring(sectorId))
end

local function resetEditableSectors()
	for _, sectorId in ipairs(EDITABLE_SECTORS) do
		local flatState = {
			sector_id = sectorId,
			mechanic = nil,
			params = {},
			pads = { ingress = "None", egress = "None" },
			version = 0,
		}
		local sector = getSectorMeta(sectorId)
		SectorApplier.apply(flatState, sector.entry, sector.exit)
		SectorRegistry.commit(flatState)
	end
	task.wait(0.1)
end

local function waitForBaseline(): boolean
	local deadline = os.clock() + 60
	while os.clock() < deadline do
		if workspace:GetAttribute("AutoTrack_BaselineLapDone") == true then
			return true
		end
		task.wait(0.25)
	end
	return false
end

local function debugLine(line: string)
	local tagged = "[DEBUG] " .. line
	print(tagged)
	TestSession.appendLine(tagged)
end

local function runCommittedLap()
	local sectors = RuntimeContext.getSectors()
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors)
	local car = RuntimeContext.getCar()
	local canonicalStart = RuntimeContext.getCanonicalStart()
	VerifierCar.reset(canonicalStart)
	return VerifierController.runLap(
		car,
		waypoints,
		waypointSectors,
		sectorKinds,
		nil,
		nil,
		nil,
		nil
	)
end

function TestPhase16.run()
	local plainRequest = makeRequest("add ramp in sector 3")
	local initialState, initialErr = MinimalProposer.initial(plainRequest)
	T.expect(
		"phase16_plain_ramp_default_is_conservative",
		initialErr == nil
			and initialState ~= nil
			and initialState.mechanic == "RampJump"
			and initialState.params.ramp_angle <= 5
			and initialState.params.gap_length <= 3
			and initialState.params.ramp_length >= 22
			and initialState.params.landing_length >= 34
			and initialState.pads.ingress == "Brake25"
			and initialState.pads.egress == "Brake10",
		tostring(initialErr or HttpService:JSONEncode(initialState or {}))
	)

	LLMAdapter.setProvider("phase16-ramp-normalize", {
		propose = function()
			return HttpService:JSONEncode({
				sector_id = 3,
				mechanic = "RampJump",
				params = {
					ramp_angle = 60,
					ramp_length = 40,
					gap_length = 40,
					landing_length = 4,
				},
				pads = {
					ingress = "None",
					egress = "None",
				},
				version = 0,
			})
		end,
		repair = function()
			return HttpService:JSONEncode({
				action = { type = "SetPad", pad = "ingress", value = "Brake10" },
				explanation = "stub",
			})
		end,
		orchestrate = function()
			return HttpService:JSONEncode({ action = "begin_loop" })
		end,
	})

	local normalizedProposal, normalizedErr = LLMAdapter.propose(plainRequest)
	T.expect(
		"phase16_llm_ramp_proposal_normalized_safe",
		normalizedErr == nil
			and normalizedProposal ~= nil
			and normalizedProposal.mechanic == "RampJump"
			and normalizedProposal.params.ramp_angle <= 5
			and normalizedProposal.params.gap_length <= 3
			and normalizedProposal.params.ramp_length >= 22
			and normalizedProposal.params.landing_length >= 34
			and normalizedProposal.pads.ingress == "Brake25"
			and normalizedProposal.pads.egress == "Brake10",
		tostring(normalizedErr or HttpService:JSONEncode(normalizedProposal or {}))
	)
	LLMAdapter.useMockProvider()

	local aggressiveProfile = RampJumpPath.buildProfile(12, 18, 2, 30)
	local firstClimbIndex = nil
	for index = 2, #aggressiveProfile.rampPoints do
		if aggressiveProfile.rampPoints[index].Y > aggressiveProfile.rampPoints[index - 1].Y + 1e-4 then
			firstClimbIndex = index
			break
		end
	end
	local entrySlope = math.huge
	local laterSlope = 0
	if firstClimbIndex ~= nil then
		local startPoint = aggressiveProfile.rampPoints[firstClimbIndex - 1]
		local endPoint = aggressiveProfile.rampPoints[firstClimbIndex]
		entrySlope = (endPoint.Y - startPoint.Y) / math.max(1e-4, endPoint.Z - startPoint.Z)
	end
	if #aggressiveProfile.rampPoints >= 2 then
		local penultimate = aggressiveProfile.rampPoints[#aggressiveProfile.rampPoints - 1]
		local last = aggressiveProfile.rampPoints[#aggressiveProfile.rampPoints]
		laterSlope = (last.Y - penultimate.Y) / math.max(1e-4, last.Z - penultimate.Z)
	end
	T.expect(
		"phase16_ramp_profile_blends_instead_of_walling",
		firstClimbIndex ~= nil and entrySlope > 0 and laterSlope > 0 and entrySlope < laterSlope * 0.35,
		HttpService:JSONEncode({
			first_climb_index = firstClimbIndex,
			entry_slope = entrySlope,
			later_slope = laterSlope,
		})
	)

	local frozenDirection, frozenVelocity, nextFrozen = VerifierController._resolveRampJumpAirborneGuidance(
		true,
		true,
		true,
		nil,
		Vector3.zAxis,
		Vector3.xAxis,
		14,
		80
	)
	T.expect(
		"phase16_ramp_airborne_guidance_freezes_takeoff_heading",
		nextFrozen ~= nil
			and frozenVelocity ~= nil
			and frozenDirection:Dot(Vector3.zAxis) > 0.99
			and frozenVelocity.Z > 79
			and math.abs(frozenVelocity.X) < 0.1
			and frozenVelocity.Y == 14,
		HttpService:JSONEncode({
			direction = { x = frozenDirection.X, y = frozenDirection.Y, z = frozenDirection.Z },
			velocity = frozenVelocity and { x = frozenVelocity.X, y = frozenVelocity.Y, z = frozenVelocity.Z } or nil,
			next_frozen = nextFrozen and { x = nextFrozen.X, y = nextFrozen.Y, z = nextFrozen.Z } or nil,
		})
	)

	local pinnedAngularVelocity = VerifierController._resolveStraightPinnedAngularVelocity(
		false,
		true,
		1,
		Vector3.new(2.5, 5, -4)
	)
	T.expect(
		"phase16_straight_pin_kills_yaw_and_roll",
		math.abs(pinnedAngularVelocity.X - 2.5) < 1e-4
			and math.abs(pinnedAngularVelocity.Y) <= 0.75
			and math.abs(pinnedAngularVelocity.Z) <= 0.75,
		HttpService:JSONEncode({
			x = pinnedAngularVelocity.X,
			y = pinnedAngularVelocity.Y,
			z = pinnedAngularVelocity.Z,
		})
	)

	local integrityOk, integrityHints = RampJumpIntegrity.evaluateRuntime({
		target_airborne = false,
		target_air_distance = 0,
		target_vertical_displacement = Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT + Constants.RAMPJUMP_COMFORT_VERTICAL_MARGIN + 0.25,
		target_reacquired = true,
		target_reacquire_distance = Constants.RAMPJUMP_REACQUIRE_MAX - Constants.RAMPJUMP_COMFORT_REACQUIRE_MARGIN - 1,
		target_exit_angular_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_ANGULAR_SPEED - 0.5,
		target_exit_vertical_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_VERTICAL_SPEED - 1,
	})
	T.expect(
		"phase16_ramp_integrity_allows_playable_rollover",
		integrityOk == true and #integrityHints == 0,
		table.concat(integrityHints, "; ")
	)

	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase16_live_ramp_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase16_live_ramp_baseline_ready", "baseline lap did not complete before ramp tuning run")
		return
	end

	resetEditableSectors()
	local sector = getSectorMeta(3)
	local liveState = makeState(3, {
		ramp_angle = 5,
		ramp_length = 26,
		gap_length = 2,
		landing_length = 36,
	}, "Brake25", "Brake10")
	local result = select(1, AttemptRunner.run({
		workingState = liveState,
		action = nil,
		targetSectorId = liveState.sector_id,
		entryFrame = sector.entry,
		exitFrame = sector.exit,
		sectors = RuntimeContext.getSectors(),
		car = RuntimeContext.getCar(),
		canonicalStart = RuntimeContext.getCanonicalStart(),
		onSectorChange = nil,
	}))
	debugLine("phase16_live_result=" .. HttpService:JSONEncode({
		success = result.success,
		failure = result.failure,
		progress = result.metrics.target_progress,
		reacquired = result.metrics.target_reacquired,
		vertical = result.metrics.target_vertical_displacement,
	}))
	T.expect(
		"phase16_sector3_ramp_attempt_playable",
		result.success == true,
		HttpService:JSONEncode({
			failure = result.failure,
			progress = result.metrics.target_progress,
			reacquired = result.metrics.target_reacquired,
			vertical = result.metrics.target_vertical_displacement,
			entry = result.metrics.entry_speed,
			exit = result.metrics.exit_speed,
		})
	)

	resetEditableSectors()
	local demoStartOk, demoStartErr = CameraDemo.start({
		preset = "rampitup",
		loop = true,
		runVerifier = false,
	})
	T.expect(
		"phase16_rampitup_demo_preset_starts",
		demoStartOk == true and demoStartErr == nil,
		tostring(demoStartErr)
	)
	local demoLap = runCommittedLap()
	debugLine("phase16_rampitup_demo_result=" .. HttpService:JSONEncode({
		success = demoLap.success,
		failure = demoLap.failure,
		lap_time = demoLap.metrics.lap_time,
		sector3_progress = demoLap.metrics.sector_peak_progress and demoLap.metrics.sector_peak_progress[3],
		sector8_progress = demoLap.metrics.sector_peak_progress and demoLap.metrics.sector_peak_progress[8],
	}))
	T.expect(
		"phase16_rampitup_demo_lap_succeeds",
		demoLap.success == true,
		HttpService:JSONEncode({
			failure = demoLap.failure,
			lap_time = demoLap.metrics.lap_time,
			sector3_body = demoLap.metrics.sector_peak_body_distance and demoLap.metrics.sector_peak_body_distance[3],
			sector8_body = demoLap.metrics.sector_peak_body_distance and demoLap.metrics.sector_peak_body_distance[8],
			sector3_progress = demoLap.metrics.sector_peak_progress and demoLap.metrics.sector_peak_progress[3],
			sector8_progress = demoLap.metrics.sector_peak_progress and demoLap.metrics.sector_peak_progress[8],
		})
	)
	local demoStopOk, demoStopErr = CameraDemo.stop()
	T.expect(
		"phase16_rampitup_demo_preset_stops",
		demoStopOk == true and demoStopErr == nil,
		tostring(demoStopErr)
	)

	resetEditableSectors()
end

return TestPhase16
