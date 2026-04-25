--!strict
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local T = require(script.Parent.TestUtils)
local AttemptRunner = require(script.Parent.AttemptRunner)
local RuntimeContext = require(script.Parent.RuntimeContext)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local MetricCollector = require(script.Parent.Parent.Verifier.MetricCollector)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local ChicaneIntegrity = require(script.Parent.Parent.Integrity.ChicaneIntegrity)
local CrestDipIntegrity = require(script.Parent.Parent.Integrity.CrestDipIntegrity)
local LapEvaluator = require(script.Parent.Parent.Integrity.LapEvaluator)

type SectorState = Types.SectorState
type SectorMeta = Types.SectorMeta

local TestPhase18 = {}
local EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }

local function makeState(
	sectorId: number,
	mechanic: Types.Mechanic?,
	params: Types.SectorParams?,
	ingress: Types.PadValue?,
	egress: Types.PadValue?
): SectorState
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		params = params or {},
		pads = {
			ingress = ingress or "None",
			egress = egress or "None",
		},
		version = 0,
	}
end

local function getSectorMeta(sectorId: number): SectorMeta
	local sectors = TrackGenerator.generate()
	for _, sector in ipairs(sectors) do
		if sector.id == sectorId then
			return sector
		end
	end
	error("sector not found: " .. tostring(sectorId))
end

local function applyState(state: SectorState)
	local sector = getSectorMeta(state.sector_id)
	SectorApplier.apply(state, sector.entry, sector.exit)
end

local function resetEditableSectors()
	for _, sectorId in ipairs(EDITABLE_SECTORS) do
		local flatState = makeState(sectorId, nil, {}, "None", "None")
		applyState(flatState)
		SectorRegistry.commit(flatState)
	end
	task.wait(0.1)
end

local function runAttemptState(state: SectorState): Types.RunResult
	local targetSector = getSectorMeta(state.sector_id)
	return select(
		1,
		AttemptRunner.run({
			workingState = state,
			action = nil,
			targetSectorId = state.sector_id,
			entryFrame = targetSector.entry,
			exitFrame = targetSector.exit,
			sectors = RuntimeContext.getSectors(),
			car = RuntimeContext.getCar(),
			canonicalStart = RuntimeContext.getCanonicalStart(),
			onSectorChange = nil,
		})
	)
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

local function testEntrySnapProfiles()
	T.expect("phase18_corner_to_corner_handoff_skips_snap", VerifierController._shouldSnapOnSectorEntry(5, 6, {
		[5] = "Corner",
		[6] = "Corner",
	}) == false and VerifierController._shouldSnapOnSectorEntry(1, 2, {
		[1] = "Corner",
		[2] = "Straight",
	}) == true, "corner-to-corner handoff should bypass entry snap")

	local cornerCFrame, cornerVelocity, cornerSpeed = VerifierController._buildSectorEntrySnap(
		Vector3.new(10, 4, 20),
		CFrame.lookAt(Vector3.zero, Vector3.new(0, 10, 10)),
		"Corner",
		nil
	)
	T.expect(
		"phase18_corner_entry_snap_is_upright_and_slow",
		math.abs(cornerCFrame.LookVector.Y) < 1e-4
			and math.abs(cornerSpeed - (Constants.CAR_TARGET_SPEED * Constants.SECTOR_ENTRY_SNAP_CORNER_SPEED_FACTOR)) < 1e-4
			and math.abs(cornerVelocity.Magnitude - cornerSpeed) < 1e-4,
		HttpService:JSONEncode({
			look_y = cornerCFrame.LookVector.Y,
			speed = cornerSpeed,
			velocity = cornerVelocity.Magnitude,
		})
	)

	local rampState = makeState(3, "RampJump", {
		ramp_angle = 4,
		ramp_length = 24,
		gap_length = 2,
		landing_length = 34,
	}, "Brake25", "Brake10")
	local rampCFrame, _, rampSpeed = VerifierController._buildSectorEntrySnap(
		Vector3.new(0, 3, 0),
		CFrame.lookAt(Vector3.zero, Vector3.new(4, 12, 20)),
		"Straight",
		rampState
	)
	T.expect(
		"phase18_ramp_entry_snap_uses_mechanic_profile",
		math.abs(rampCFrame.LookVector.Y) < 1e-4
			and math.abs(
					rampSpeed - (Constants.CAR_TARGET_SPEED * Constants.SECTOR_ENTRY_SNAP_RAMPJUMP_SPEED_FACTOR)
				)
				< 1e-4,
		HttpService:JSONEncode({
			look_y = rampCFrame.LookVector.Y,
			speed = rampSpeed,
		})
	)
end

local function testMetricTelemetry()
	MetricCollector.reset(0, 3)
	MetricCollector.onSectorEntry(3, 22)
	MetricCollector.record(22, Vector3.new(0, 0, 0), true, 0, 0, 0, 3.2)
	MetricCollector.record(22, Vector3.new(0, 0, 6), true, 0, 0, 0.1, 4.4)
	MetricCollector.record(20, Vector3.new(0, 0, 12), false, 0, 0, 0.2, 4.1)
	MetricCollector.onSectorExit(3, 24, 1.4, -6)
	local metrics = MetricCollector.finalise(3, 30, 30)

	T.expect(
		"phase18_metric_collector_tracks_margin_telemetry",
		math.abs((metrics.target_reacquire_distance or 0) - 12) < 0.2
			and math.abs((metrics.target_peak_body_distance or 0) - 4.4) < 0.2
			and math.abs((metrics.target_exit_angular_speed or 0) - 1.4) < 0.05
			and math.abs((metrics.target_exit_vertical_speed or 0) - 6) < 0.05,
		HttpService:JSONEncode({
			target_reacquire_distance = metrics.target_reacquire_distance,
			target_peak_body_distance = metrics.target_peak_body_distance,
			target_exit_angular_speed = metrics.target_exit_angular_speed,
			target_exit_vertical_speed = metrics.target_exit_vertical_speed,
		})
	)
end

local function testComfortGates()
	local ok, hints = RampJumpIntegrity.evaluateRuntime({
		target_vertical_displacement = Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT
			+ Constants.RAMPJUMP_COMFORT_VERTICAL_MARGIN
			+ 0.25,
		target_reacquired = true,
		target_reacquire_distance = Constants.RAMPJUMP_REACQUIRE_MAX - Constants.RAMPJUMP_COMFORT_REACQUIRE_MARGIN - 1,
		target_exit_angular_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_ANGULAR_SPEED - 0.5,
		target_exit_vertical_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_VERTICAL_SPEED - 2,
	})
	T.expect("phase18_rampjump_comfortable_passes", ok == true and #hints == 0, table.concat(hints, "; "))

	ok, hints = RampJumpIntegrity.evaluateRuntime({
		target_vertical_displacement = Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT,
		target_reacquired = true,
		target_reacquire_distance = Constants.RAMPJUMP_REACQUIRE_MAX - 0.5,
		target_exit_angular_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_ANGULAR_SPEED + 0.25,
		target_exit_vertical_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_VERTICAL_SPEED + 1,
	})
	T.expect("phase18_rampjump_borderline_rejected", ok == false and #hints > 0, table.concat(hints, "; "))

	ok, hints = ChicaneIntegrity.evaluateRuntime({
		target_left_offset = (Constants.CHICANE_MIN_LATERAL_DISPLACEMENT * 0.5)
			+ Constants.CHICANE_COMFORT_LATERAL_MARGIN
			+ 0.5,
		target_right_offset = (Constants.CHICANE_MIN_LATERAL_DISPLACEMENT * 0.5)
			+ Constants.CHICANE_COMFORT_LATERAL_MARGIN
			+ 0.5,
		target_lateral_band_changes = Constants.CHICANE_MIN_ALTERNATIONS,
		target_peak_body_distance = Constants.FRONT_BODY_CONTAINMENT_DISTANCE
			- Constants.CHICANE_COMFORT_BODY_MARGIN
			- 0.5,
	})
	T.expect("phase18_chicane_comfortable_passes", ok == true and #hints == 0, table.concat(hints, "; "))

	ok, hints = ChicaneIntegrity.evaluateRuntime({
		target_left_offset = Constants.CHICANE_MIN_LATERAL_DISPLACEMENT * 0.5,
		target_right_offset = Constants.CHICANE_MIN_LATERAL_DISPLACEMENT * 0.5,
		target_lateral_band_changes = Constants.CHICANE_MIN_ALTERNATIONS,
		target_peak_body_distance = Constants.FRONT_BODY_CONTAINMENT_DISTANCE - 0.25,
	})
	T.expect("phase18_chicane_borderline_rejected", ok == false and #hints > 0, table.concat(hints, "; "))

	ok, hints = CrestDipIntegrity.evaluateRuntime({
		target_vertical_displacement = Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT
			+ Constants.CRESTDIP_COMFORT_VERTICAL_MARGIN
			+ 0.5,
		target_reacquired = true,
		target_reacquire_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE
			- Constants.CRESTDIP_COMFORT_AIRTIME_MARGIN
			- 2,
		target_apex_min_speed = Constants.CRESTDIP_APEX_MIN_SPEED + Constants.CRESTDIP_COMFORT_APEX_SPEED_MARGIN + 2,
		target_exit_angular_speed = Constants.CRESTDIP_COMFORT_EXIT_MAX_ANGULAR_SPEED - 0.5,
		target_exit_vertical_speed = Constants.CRESTDIP_COMFORT_EXIT_MAX_VERTICAL_SPEED - 1,
	})
	T.expect("phase18_crestdip_comfortable_passes", ok == true and #hints == 0, table.concat(hints, "; "))

	ok, hints = CrestDipIntegrity.evaluateRuntime({
		target_vertical_displacement = Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT + 0.1,
		target_airborne = true,
		target_reacquired = true,
		target_reacquire_distance = Constants.CRESTDIP_MAX_AIRTIME_DISTANCE - 1,
		target_apex_min_speed = Constants.CRESTDIP_APEX_MIN_SPEED + 0.5,
		target_exit_angular_speed = Constants.CRESTDIP_COMFORT_EXIT_MAX_ANGULAR_SPEED + 0.25,
		target_exit_vertical_speed = Constants.CRESTDIP_COMFORT_EXIT_MAX_VERTICAL_SPEED + 0.5,
	})
	T.expect("phase18_crestdip_borderline_rejected", ok == false and #hints > 0, table.concat(hints, "; "))

	local rampState = makeState(3, "RampJump", {
		ramp_angle = 4,
		ramp_length = 24,
		gap_length = 2,
		landing_length = 34,
	}, "Brake25", "Brake10")
	local result, evaluatorHints = LapEvaluator.evaluate(nil, rampState, {
		entry_speed = 22,
		exit_speed = 20,
		airborne = true,
		air_distance = 8,
		lateral_error = 0.5,
		vertical_displacement = 0,
		reacquired = true,
		airtime_distance = 8,
		target_airborne = true,
		target_air_distance = 8,
		target_vertical_displacement = Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT,
		target_reacquired = true,
		target_airtime_distance = Constants.RAMPJUMP_REACQUIRE_MAX - 0.5,
		target_entered = true,
		target_exited = true,
		target_progress = 1,
		target_reacquire_distance = Constants.RAMPJUMP_REACQUIRE_MAX - 0.5,
		target_exit_angular_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_ANGULAR_SPEED + 0.5,
		target_exit_vertical_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_VERTICAL_SPEED + 1,
		lap_time = 24,
		slowdown_ratio = 1,
	}, 3)
	T.expect(
		"phase18_lapevaluator_rejects_borderline_completion",
		result.success == false
			and result.failure ~= nil
			and result.failure.type == "mechanic_integrity_failure"
			and #evaluatorHints > 0,
		HttpService:JSONEncode({
			success = result.success,
			failure = result.failure,
			hints = evaluatorHints,
		})
	)
end

local function testLiveReliability()
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		T.fail("phase18_live_requires_baseline", "restart without AutoTrack_SkipBootBaseline")
		return
	end
	if not waitForBaseline() then
		T.fail("phase18_live_baseline_ready", "baseline lap did not complete before Phase 18 validation")
		return
	end

	resetEditableSectors()
	local rampResult = runAttemptState(makeState(3, "RampJump", {
		ramp_angle = 5,
		ramp_length = 26,
		gap_length = 2,
		landing_length = 36,
	}, "Brake25", "Brake10"))
	T.expect(
		"phase18_live_rampjump_survives_with_margin",
		rampResult.success == true,
		HttpService:JSONEncode({
			failure = rampResult.failure,
			progress = rampResult.metrics.target_progress,
			reacquire = rampResult.metrics.target_reacquire_distance,
			exit_ang = rampResult.metrics.target_exit_angular_speed,
			exit_vert = rampResult.metrics.target_exit_vertical_speed,
		})
	)

	resetEditableSectors()
	local chicaneResult = runAttemptState(makeState(3, "Chicane", {
		amplitude = 5,
		transition_length = 26,
		corridor_width = 18,
	}, "Brake25", "Brake10"))
	T.expect(
		"phase18_live_chicane_survives_with_margin",
		chicaneResult.success == true,
		HttpService:JSONEncode({
			failure = chicaneResult.failure,
			progress = chicaneResult.metrics.target_progress,
			body = chicaneResult.metrics.target_peak_body_distance,
			left = chicaneResult.metrics.target_left_offset,
			right = chicaneResult.metrics.target_right_offset,
		})
	)

	resetEditableSectors()
	local crestResult = runAttemptState(makeState(3, "CrestDip", {
		height_or_depth = 5,
		radius = LevelMappings.DEFAULTS.CrestDip.radius,
		sector_length = 30,
	}, "Brake50", "None"))
	T.expect(
		"phase18_live_crestdip_survives_with_margin",
		crestResult.success == true,
		HttpService:JSONEncode({
			failure = crestResult.failure,
			progress = crestResult.metrics.target_progress,
			reacquire = crestResult.metrics.target_reacquire_distance,
			apex = crestResult.metrics.target_apex_min_speed,
			exit_ang = crestResult.metrics.target_exit_angular_speed,
			exit_vert = crestResult.metrics.target_exit_vertical_speed,
		})
	)

	resetEditableSectors()
end

function TestPhase18.run()
	testEntrySnapProfiles()
	testMetricTelemetry()
	testComfortGates()
	testLiveReliability()
end

return TestPhase18
