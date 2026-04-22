local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local LevelMappings = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("LevelMappings"))
local T = require(script.Parent.TestUtils)
local AttemptRunner = require(script.Parent.AttemptRunner)
local HotfixAgent = require(script.Parent.HotfixAgent)
local JobRunner = require(script.Parent.JobRunner)
local RuntimeContext = require(script.Parent.RuntimeContext)
local TuneExperiment = require(script.Parent.TuneExperiment)
local TuneLab = require(script.Parent.TuneLab)
local TuneMode = require(script.Parent.TuneMode)
local UIState = require(script.Parent.UIState)
local ChicaneIntegrity = require(script.Parent.Parent.Integrity.ChicaneIntegrity)
local CrestDipIntegrity = require(script.Parent.Parent.Integrity.CrestDipIntegrity)
local RampJumpIntegrity = require(script.Parent.Parent.Integrity.RampJumpIntegrity)
local RampJumpTuner = require(script.Parent.Parent.Mechanics.RampJumpTuner)
local FailureDetector = require(script.Parent.Parent.Verifier.FailureDetector)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local SectorRegistry = require(script.Parent.Parent.Track.SectorRegistry)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)

type SectorState = Types.SectorState

local TestPhase21 = {}
local EDITABLE_SECTORS = { 2, 3, 4, 7, 8, 9 }

local function cloneParams(params)
	local result = {}
	for key, value in pairs(params or {}) do
		result[key] = value
	end
	return result
end

local function makeState(sectorId: number, mechanic, params, ingress, egress): SectorState
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		params = cloneParams(params),
		pads = {
			ingress = ingress or "None",
			egress = egress or "None",
		},
		version = 0,
	}
end

local function waitUntil(predicate, timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		task.wait(0.1)
	end
	return predicate()
end

local function resetEditableSectors()
	for _, sectorId in ipairs(EDITABLE_SECTORS) do
		local sector = RuntimeContext.getSectorById(sectorId)
		local flatState = makeState(sectorId, nil, {}, "None", "None")
		SectorApplier.apply(flatState, sector.entry, sector.exit)
		SectorRegistry.commit(flatState)
		UIState.setSectorMechanic(sectorId, nil)
	end
	for _, spec in pairs(TuneLab.ATTR_SPECS) do
		workspace:SetAttribute(spec.workspace_attr, nil)
	end
	task.wait(0.1)
end

local function submitEventually(command: string, timeoutSeconds: number): (boolean, string?)
	local deadline = os.clock() + timeoutSeconds
	local lastReason = nil
	repeat
		local ok, reason = JobRunner.submit(command)
		if ok then
			return true, nil
		end
		lastReason = tostring(reason)
		if string.find(lastReason, "tune pass in flight", 1, true) == nil
			and string.find(lastReason, "tune run in flight", 1, true) == nil
		then
			return false, lastReason
		end
		task.wait(0.15)
	until os.clock() >= deadline
	return false, lastReason
end

local function waitForTunePassCount(stateFolder, minPassCount: number)
	return waitUntil(function()
		return stateFolder:GetAttribute("tune_mode_active") == true
			and (stateFolder:GetAttribute("tune_pass_count") or 0) >= minPassCount
	end, 12)
end

local function ensureReady()
	local ready = waitUntil(function()
		return RuntimeContext.isReady()
	end, 60)
	T.expect("phase21_runtime_context_ready", ready, "runtime context not ready")
	if not ready then
		return false
	end
	if TuneMode.isActive() then
		TuneMode.stop()
		waitUntil(function()
			return not TuneMode.isActive()
		end, 5)
	end
	resetEditableSectors()
	return true
end

local function testSectorPath()
	local sector = RuntimeContext.getSectorById(3)
	local state = makeState(3, "RampJump", LevelMappings.DEFAULTS.RampJump, "None", "None")
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getSectorPath(sector, state)
	local rideY = sector.entry.Position.Y + 2
	T.expect(
		"phase21_sector_path_starts_at_entry_and_stays_in_one_sector",
		#waypoints >= 2
			and #waypointSectors == #waypoints
			and sectorKinds[3] == "Straight"
			and (waypoints[1].Position - Vector3.new(sector.entry.Position.X, rideY, sector.entry.Position.Z)).Magnitude < 0.05
			and waypointSectors[1] == 3
			and waypointSectors[#waypointSectors] == 3,
		HttpService:JSONEncode({
			count = #waypoints,
			first_x = waypoints[1].Position.X,
			first_y = waypoints[1].Position.Y,
			first_z = waypoints[1].Position.Z,
			last_sector = waypointSectors[#waypointSectors],
		})
	)
end

local function testIsolatedAttempt()
	local sector = RuntimeContext.getSectorById(3)
	local function runOnce()
		return select(1, AttemptRunner.run({
			mode = "isolated_sector",
			workingState = makeState(3, nil, {}, "None", "None"),
			action = nil,
			targetSectorId = 3,
			entryFrame = sector.entry,
			exitFrame = sector.exit,
			sectors = RuntimeContext.getSectors(),
			car = RuntimeContext.getCar(),
			canonicalStart = RuntimeContext.getCanonicalStart(),
			onSectorChange = nil,
		}))
	end

	task.wait(0.2)
	local firstResult = runOnce()
	local result = firstResult
	if result.success ~= true then
		resetEditableSectors()
		task.wait(0.2)
		result = runOnce()
	end
	T.expect(
		"phase21_isolated_attempt_flat_sector_succeeds",
		result.success == true and result.failure == nil,
		HttpService:JSONEncode({
			first = {
				success = firstResult.success,
				failure = firstResult.failure,
				lap_time = firstResult.metrics and firstResult.metrics.lap_time or -1,
				slowdown_ratio = firstResult.metrics and firstResult.metrics.slowdown_ratio or -1,
			},
			final = {
				success = result.success,
				failure = result.failure,
				lap_time = result.metrics and result.metrics.lap_time or -1,
				slowdown_ratio = result.metrics and result.metrics.slowdown_ratio or -1,
			},
		})
	)
end

local function testIsolatedEntrySnapUsesBaseSpeedOverride()
	local rampState = makeState(3, "RampJump", LevelMappings.DEFAULTS.RampJump, "None", "None")
	local _, _, isolatedRampSpeed = VerifierController._buildSectorEntrySnap(
		Vector3.new(0, 3, 0),
		CFrame.lookAt(Vector3.zero, Vector3.new(0, 4, 20)),
		"Straight",
		rampState,
		nil,
		true
	)
	local _, _, isolatedCrestSpeed = VerifierController._buildSectorEntrySnap(
		Vector3.new(0, 3, 0),
		CFrame.lookAt(Vector3.zero, Vector3.new(0, 4, 20)),
		"Straight",
		makeState(3, "CrestDip", LevelMappings.DEFAULTS.CrestDip, "None", "None"),
		nil,
		true
	)
	T.expect(
		"phase21_isolated_entry_snap_uses_straight_baseline_speed",
		math.abs(isolatedRampSpeed - Constants.CAR_TARGET_SPEED) < 1e-4
			and math.abs(isolatedCrestSpeed - Constants.CAR_TARGET_SPEED) < 1e-4,
		HttpService:JSONEncode({
			ramp_speed = isolatedRampSpeed,
			crest_speed = isolatedCrestSpeed,
			target = Constants.CAR_TARGET_SPEED,
		})
	)

	workspace:SetAttribute("AutoTrack_CarTargetSpeed", 130)
	local _, _, overrideSpeed = VerifierController._buildSectorEntrySnap(
		Vector3.new(0, 3, 0),
		CFrame.lookAt(Vector3.zero, Vector3.new(0, 4, 20)),
		"Straight",
		rampState,
		nil,
		true
	)
	T.expect(
		"phase21_isolated_entry_snap_uses_tune_base_speed_override",
		math.abs(overrideSpeed - 130) < 1e-4,
		HttpService:JSONEncode({
			override_speed = overrideSpeed,
		})
	)
	workspace:SetAttribute("AutoTrack_CarTargetSpeed", nil)
end

local function testProductionNormalizerStaysConservative()
	local tuned = RampJumpTuner.tune({
		ramp_angle = 18,
		ramp_length = 72,
		gap_length = 24,
		landing_length = 72,
	})
	T.expect(
		"phase21_production_rampjump_tuner_stays_on_production_bounds",
		tuned.ramp_angle <= LevelMappings.LEVER_BOUNDS.RampJump.ramp_angle.max
			and tuned.gap_length <= LevelMappings.LEVER_BOUNDS.RampJump.gap_length.max
			and tuned.ramp_length <= LevelMappings.LEVER_BOUNDS.RampJump.ramp_length.max
			and tuned.landing_length <= LevelMappings.LEVER_BOUNDS.RampJump.landing_length.max,
		HttpService:JSONEncode(tuned)
	)
end

local function testRuntimeIntegrityAndContainmentAttrs()
	local offTrackDistance = Constants.OFF_TRACK_FAILURE_DISTANCE + 2
	FailureDetector.reset()
	local defaultFailure = FailureDetector.check(
		0,
		3,
		Vector3.new(offTrackDistance, 0, 0),
		Vector3.zero,
		false,
		30,
		0,
		1,
		1
	)
	T.expect(
		"phase21_default_offtrack_threshold_still_fails",
		defaultFailure ~= nil and defaultFailure.detail == "off_track",
		HttpService:JSONEncode(defaultFailure or {})
	)
	workspace:SetAttribute("AutoTrack_OffTrackFailureDistance", offTrackDistance + 1)
	FailureDetector.reset()
	local relaxedFailure = FailureDetector.check(
		0,
		3,
		Vector3.new(offTrackDistance, 0, 0),
		Vector3.zero,
		false,
		30,
		0,
		1,
		1
	)
	T.expect(
		"phase21_runtime_offtrack_threshold_override_applies",
		relaxedFailure == nil,
		tostring(relaxedFailure and relaxedFailure.detail)
	)
	workspace:SetAttribute("AutoTrack_OffTrackFailureDistance", nil)

	local rampMetrics = {
		reacquired = true,
		target_reacquired = true,
		target_vertical_displacement = Constants.RAMPJUMP_MIN_VERTICAL_DISPLACEMENT + 0.1,
		target_reacquire_distance = Constants.RAMPJUMP_REACQUIRE_MAX - Constants.RAMPJUMP_COMFORT_REACQUIRE_MARGIN - 1,
		target_exit_angular_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_ANGULAR_SPEED - 0.5,
		target_exit_vertical_speed = Constants.RAMPJUMP_COMFORT_EXIT_MAX_VERTICAL_SPEED - 1,
	}
	local rampDefaultOk = select(1, RampJumpIntegrity.evaluateRuntime(rampMetrics))
	T.expect("phase21_default_rampjump_comfort_margin_rejects_borderline_case", rampDefaultOk == false, tostring(rampDefaultOk))
	workspace:SetAttribute("AutoTrack_RampJumpComfortVerticalMargin", 0)
	local rampRelaxedOk = select(1, RampJumpIntegrity.evaluateRuntime(rampMetrics))
	T.expect("phase21_runtime_rampjump_comfort_margin_override_applies", rampRelaxedOk == true, tostring(rampRelaxedOk))
	workspace:SetAttribute("AutoTrack_RampJumpComfortVerticalMargin", nil)

	local chicaneMetrics = {
		target_left_offset = (Constants.CHICANE_MIN_LATERAL_DISPLACEMENT * 0.5) + Constants.CHICANE_COMFORT_LATERAL_MARGIN + 0.5,
		target_right_offset = (Constants.CHICANE_MIN_LATERAL_DISPLACEMENT * 0.5) + Constants.CHICANE_COMFORT_LATERAL_MARGIN + 0.5,
		target_lateral_band_changes = Constants.CHICANE_MIN_ALTERNATIONS,
		target_peak_body_distance = Constants.FRONT_BODY_CONTAINMENT_DISTANCE - 0.25,
	}
	local chicaneDefaultOk = select(1, ChicaneIntegrity.evaluateRuntime(chicaneMetrics))
	T.expect("phase21_default_chicane_body_margin_rejects_borderline_case", chicaneDefaultOk == false, tostring(chicaneDefaultOk))
	workspace:SetAttribute("AutoTrack_ChicaneComfortBodyMargin", 0)
	local chicaneRelaxedOk = select(1, ChicaneIntegrity.evaluateRuntime(chicaneMetrics))
	T.expect("phase21_runtime_chicane_body_margin_override_applies", chicaneRelaxedOk == true, tostring(chicaneRelaxedOk))
	workspace:SetAttribute("AutoTrack_ChicaneComfortBodyMargin", nil)

	local crestMetrics = {
		target_vertical_displacement = Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT + Constants.CRESTDIP_COMFORT_VERTICAL_MARGIN + 1,
		target_airborne = false,
		target_reacquired = true,
		target_apex_min_speed = Constants.CRESTDIP_APEX_MIN_SPEED + 1,
		target_exit_angular_speed = Constants.CRESTDIP_COMFORT_EXIT_MAX_ANGULAR_SPEED - 0.5,
		target_exit_vertical_speed = Constants.CRESTDIP_COMFORT_EXIT_MAX_VERTICAL_SPEED - 0.5,
	}
	local crestDefaultOk = select(1, CrestDipIntegrity.evaluateRuntime(crestMetrics))
	T.expect("phase21_default_crestdip_apex_margin_rejects_borderline_case", crestDefaultOk == false, tostring(crestDefaultOk))
	workspace:SetAttribute("AutoTrack_CrestDipComfortApexSpeedMargin", 0)
	local crestRelaxedOk = select(1, CrestDipIntegrity.evaluateRuntime(crestMetrics))
	T.expect("phase21_runtime_crestdip_apex_margin_override_applies", crestRelaxedOk == true, tostring(crestRelaxedOk))
	workspace:SetAttribute("AutoTrack_CrestDipComfortApexSpeedMargin", nil)
end

local function testTuneLifecycle()
	local stateFolder = UIState.getStateFolder()

	local startOk, startErr = JobRunner.submit("/tune rampjump")
	T.expect("phase21_tune_start_command_accepted", startOk == true and startErr == nil, tostring(startErr))
	T.expect(
		"phase21_tune_mode_starts_in_staged_state",
		stateFolder:GetAttribute("tune_mode_active") == true
			and (stateFolder:GetAttribute("tune_pass_count") or 0) == 0
			and stateFolder:GetAttribute("tune_run_in_flight") == false
			and stateFolder:GetAttribute("tune_auto_run") == false
			and stateFolder:GetAttribute("tune_candidate_version") == 1,
		HttpService:JSONEncode({
			active = stateFolder:GetAttribute("tune_mode_active"),
			pass_count = stateFolder:GetAttribute("tune_pass_count"),
			run_in_flight = stateFolder:GetAttribute("tune_run_in_flight"),
			auto_run = stateFolder:GetAttribute("tune_auto_run"),
			candidate_version = stateFolder:GetAttribute("tune_candidate_version"),
			last_result = stateFolder:GetAttribute("tune_last_result"),
		})
	)
	task.wait(0.6)
	T.expect(
		"phase21_tune_start_does_not_autorun_by_default",
		(stateFolder:GetAttribute("tune_pass_count") or 0) == 0 and (stateFolder:GetAttribute("tune_last_pass_json") or "") == "",
		HttpService:JSONEncode({
			pass_count = stateFolder:GetAttribute("tune_pass_count"),
			last_pass_json = stateFolder:GetAttribute("tune_last_pass_json"),
		})
	)
	T.expect(
		"phase21_tune_camera_override_armed",
		stateFolder:GetAttribute("camera_override_enabled") == true and stateFolder:GetAttribute("tune_sector_id") == 3,
		HttpService:JSONEncode({
			camera = stateFolder:GetAttribute("camera_override_enabled"),
			sector = stateFolder:GetAttribute("tune_sector_id"),
		})
	)
	T.expect(
		"phase21_tune_telemetry_exposes_machine_readable_stage_state",
		(stateFolder:GetAttribute("tune_bounds_summary") or "") ~= ""
			and (stateFolder:GetAttribute("tune_last_batch_json") or "") == ""
			and stateFolder:GetAttribute("tune_candidate_version") == 1,
		HttpService:JSONEncode({
			bounds = stateFolder:GetAttribute("tune_bounds_summary"),
			last_batch = stateFolder:GetAttribute("tune_last_batch_json"),
			candidate_version = stateFolder:GetAttribute("tune_candidate_version"),
		})
	)

	local showOk, showErr = JobRunner.submit("/tune show")
	T.expect("phase21_tune_show_accepted", showOk == true and showErr == nil, tostring(showErr))

	local setOk, setErr = JobRunner.submit("/tune set gap_length 24")
	T.expect("phase21_tune_set_updates_working_state", setOk == true and setErr == nil, tostring(setErr))
	T.expect(
		"phase21_tune_set_uses_experimental_bounds",
		string.find(stateFolder:GetAttribute("tune_param_summary") or "", "gap_length=24", 1, true) ~= nil
			and TuneMode.experimentalBounds("RampJump").gap_length.max > LevelMappings.LEVER_BOUNDS.RampJump.gap_length.max
			and stateFolder:GetAttribute("tune_candidate_version") == 2,
		HttpService:JSONEncode({
			summary = stateFolder:GetAttribute("tune_param_summary"),
			candidate_version = stateFolder:GetAttribute("tune_candidate_version"),
			experimental_gap_max = TuneMode.experimentalBounds("RampJump").gap_length.max,
			production_gap_max = LevelMappings.LEVER_BOUNDS.RampJump.gap_length.max,
		})
	)

	local setClipOk, setClipErr = JobRunner.submit("/tune set gap_length 40")
	T.expect("phase21_tune_set_clamped_command_accepted", setClipOk == true and setClipErr == nil, tostring(setClipErr))
	T.expect(
		"phase21_tune_set_clamps_to_experimental_bounds",
		string.find(stateFolder:GetAttribute("tune_param_summary") or "", "gap_length=24", 1, true) ~= nil,
		tostring(stateFolder:GetAttribute("tune_param_summary"))
	)

	local padOk, padErr = JobRunner.submit("/tune pad ingress Boost25")
	T.expect("phase21_tune_pad_updates_working_state", padOk == true and padErr == nil, tostring(padErr))
	T.expect(
		"phase21_tune_pad_updates_summary",
		string.find(stateFolder:GetAttribute("tune_param_summary") or "", "ingress=Boost25", 1, true) ~= nil,
		tostring(stateFolder:GetAttribute("tune_param_summary"))
	)

	local attrOk, attrErr = JobRunner.submit("/tune attr straight_pin_yaw_damping 55")
	T.expect("phase21_tune_attr_updates_workspace_override", attrOk == true and attrErr == nil, tostring(attrErr))
	T.expect(
		"phase21_tune_attr_summary_updates",
		workspace:GetAttribute("AutoTrack_StraightPinYawDamping") == 55
			and string.find(stateFolder:GetAttribute("tune_attr_summary") or "", "straight_pin_yaw_damping=55", 1, true) ~= nil,
		HttpService:JSONEncode({
			workspace = workspace:GetAttribute("AutoTrack_StraightPinYawDamping"),
			summary = stateFolder:GetAttribute("tune_attr_summary"),
		})
	)

	local speedAttrOk, speedAttrErr = JobRunner.submit("/tune attr car_target_speed 130")
	T.expect("phase21_tune_speed_attr_updates_workspace_override", speedAttrOk == true and speedAttrErr == nil, tostring(speedAttrErr))
	T.expect(
		"phase21_tune_speed_attr_updates_summary_and_telemetry",
		workspace:GetAttribute("AutoTrack_CarTargetSpeed") == 130
			and stateFolder:GetAttribute("tune_active_target_speed") == 130
			and string.find(stateFolder:GetAttribute("tune_attr_summary") or "", "car_target_speed=130", 1, true) ~= nil,
		HttpService:JSONEncode({
			workspace = workspace:GetAttribute("AutoTrack_CarTargetSpeed"),
			active_target_speed = stateFolder:GetAttribute("tune_active_target_speed"),
			summary = stateFolder:GetAttribute("tune_attr_summary"),
		})
	)

	local envelopeAttrOk, envelopeAttrErr = JobRunner.submit("/tune attr front_body_containment_distance 18")
	T.expect("phase21_tune_integrity_attr_updates_workspace_override", envelopeAttrOk == true and envelopeAttrErr == nil, tostring(envelopeAttrErr))
	T.expect(
		"phase21_tune_integrity_attr_updates_summary",
		workspace:GetAttribute("AutoTrack_FrontBodyContainmentDistance") == 18
			and string.find(stateFolder:GetAttribute("tune_attr_summary") or "", "front_body_containment_distance=18", 1, true) ~= nil,
		HttpService:JSONEncode({
			workspace = workspace:GetAttribute("AutoTrack_FrontBodyContainmentDistance"),
			summary = stateFolder:GetAttribute("tune_attr_summary"),
		})
	)

	local runOk, runErr = JobRunner.submit("/tune run 3")
	T.expect("phase21_tune_run_command_accepted", runOk == true and runErr == nil, tostring(runErr))
	local blockedSetOk, blockedSetErr = JobRunner.submit("/tune set gap_length 20")
	T.expect(
		"phase21_tune_mutation_blocked_while_run_in_flight",
		blockedSetOk == false and string.find(tostring(blockedSetErr), "tune run in flight", 1, true) ~= nil,
		tostring(blockedSetErr)
	)
	local runFinished = waitUntil(function()
		return (stateFolder:GetAttribute("tune_pass_count") or 0) >= 3
			and stateFolder:GetAttribute("tune_run_in_flight") == false
			and (stateFolder:GetAttribute("tune_last_batch_json") or "") ~= ""
			and (stateFolder:GetAttribute("tune_last_pass_json") or "") ~= ""
	end, 20)
	T.expect(
		"phase21_tune_run_emits_batch_and_pass_history",
		runFinished,
		HttpService:JSONEncode({
			pass_count = stateFolder:GetAttribute("tune_pass_count"),
			run_in_flight = stateFolder:GetAttribute("tune_run_in_flight"),
			last_batch = stateFolder:GetAttribute("tune_last_batch_json"),
			last_pass = stateFolder:GetAttribute("tune_last_pass_json"),
		})
	)
	local lastBatch = HttpService:JSONDecode(stateFolder:GetAttribute("tune_last_batch_json") or "{}")
	T.expect(
		"phase21_tune_run_batch_aggregate_is_parseable",
		lastBatch.candidate_version == stateFolder:GetAttribute("tune_candidate_version")
			and lastBatch.requested_passes == 3
			and lastBatch.completed_passes == 3
			and lastBatch.aggregate ~= nil
			and lastBatch.aggregate.pass_count == 3,
		HttpService:JSONEncode(lastBatch)
	)

	local autoOnOk, autoOnErr = JobRunner.submit("/tune auto on")
	T.expect("phase21_tune_auto_on_accepted", autoOnOk == true and autoOnErr == nil, tostring(autoOnErr))
	local beforeAutoPassCount = stateFolder:GetAttribute("tune_pass_count") or 0
	local autoAdvanced = waitUntil(function()
		return stateFolder:GetAttribute("tune_auto_run") == true
			and (stateFolder:GetAttribute("tune_pass_count") or 0) > beforeAutoPassCount
	end, 12)
	T.expect(
		"phase21_tune_auto_on_restarts_continuous_runs",
		autoAdvanced,
		HttpService:JSONEncode({
			auto_run = stateFolder:GetAttribute("tune_auto_run"),
			pass_count = stateFolder:GetAttribute("tune_pass_count"),
			last_batch = stateFolder:GetAttribute("tune_last_batch_json"),
		})
	)
	local autoOffOk, autoOffErr = submitEventually("/tune auto off", 8)
	T.expect("phase21_tune_auto_off_accepted", autoOffOk == true and autoOffErr == nil, tostring(autoOffErr))
	local autoStopped = waitUntil(function()
		return stateFolder:GetAttribute("tune_auto_run") == false
			and stateFolder:GetAttribute("tune_run_in_flight") == false
	end, 8)
	T.expect(
		"phase21_tune_auto_off_returns_to_staged_mode",
		autoStopped,
		HttpService:JSONEncode({
			auto_run = stateFolder:GetAttribute("tune_auto_run"),
			run_in_flight = stateFolder:GetAttribute("tune_run_in_flight"),
			last_result = stateFolder:GetAttribute("tune_last_result"),
		})
	)

	local badLeverOk, badLeverErr = JobRunner.submit("/tune set amplitude 12")
	T.expect(
		"phase21_tune_invalid_lever_rejected",
		badLeverOk == false and string.find(tostring(badLeverErr), "invalid tune lever", 1, true) ~= nil,
		tostring(badLeverErr)
	)

	local badAttrOk, badAttrErr = JobRunner.submit("/tune attr nope 1")
	T.expect(
		"phase21_tune_invalid_attr_rejected",
		badAttrOk == false and string.find(tostring(badAttrErr), "unknown tune attr", 1, true) ~= nil,
		tostring(badAttrErr)
	)

	local resetOk, resetErr = JobRunner.submit("/tune reset")
	T.expect("phase21_tune_reset_accepted", resetOk == true and resetErr == nil, tostring(resetErr))
	T.expect(
		"phase21_tune_reset_clears_attr_overrides",
		workspace:GetAttribute("AutoTrack_StraightPinYawDamping") == nil
			and workspace:GetAttribute("AutoTrack_CarTargetSpeed") == nil
			and workspace:GetAttribute("AutoTrack_FrontBodyContainmentDistance") == nil
			and (stateFolder:GetAttribute("tune_attr_summary") or "") == ""
			and (stateFolder:GetAttribute("tune_active_target_speed") or 0) == 0,
		HttpService:JSONEncode({
			yaw = workspace:GetAttribute("AutoTrack_StraightPinYawDamping"),
			speed = workspace:GetAttribute("AutoTrack_CarTargetSpeed"),
			body = workspace:GetAttribute("AutoTrack_FrontBodyContainmentDistance"),
			summary = stateFolder:GetAttribute("tune_attr_summary"),
			active_target_speed = stateFolder:GetAttribute("tune_active_target_speed"),
		})
	)

	local setCommitOk, setCommitErr = JobRunner.submit("/tune set gap_length 24")
	T.expect("phase21_tune_set_before_commit_accepted", setCommitOk == true and setCommitErr == nil, tostring(setCommitErr))
	local commitOk, commitErr = submitEventually("/tune commit", 6)
	T.expect("phase21_tune_commit_accepted", commitOk == true and commitErr == nil, tostring(commitErr))
	local committed = SectorRegistry.getCommitted(3)
	T.expect(
		"phase21_tune_commit_persists_sector_state",
		committed ~= nil
			and committed.mechanic == "RampJump"
			and committed.params.gap_length == 24
			and stateFolder:GetAttribute("tune_mode_active") == true,
		HttpService:JSONEncode(committed or {})
	)

	local setRevertOk, setRevertErr = JobRunner.submit("/tune set gap_length 2")
	T.expect("phase21_tune_set_before_revert_accepted", setRevertOk == true and setRevertErr == nil, tostring(setRevertErr))
	local revertOk, revertErr = JobRunner.submit("/tune revert")
	T.expect("phase21_tune_revert_accepted", revertOk == true and revertErr == nil, tostring(revertErr))
	T.expect(
		"phase21_tune_revert_restores_committed_state",
		string.find(stateFolder:GetAttribute("tune_param_summary") or "", "gap_length=24", 1, true) ~= nil
			and workspace:GetAttribute("AutoTrack_CarTargetSpeed") == nil,
		HttpService:JSONEncode({
			summary = stateFolder:GetAttribute("tune_param_summary"),
			speed = workspace:GetAttribute("AutoTrack_CarTargetSpeed"),
		})
	)

	local stopOk, stopErr = JobRunner.submit("/tune stop")
	T.expect("phase21_tune_stop_accepted", stopOk == true and stopErr == nil, tostring(stopErr))
	local stopped = waitUntil(function()
		return stateFolder:GetAttribute("tune_mode_active") == false
			and stateFolder:GetAttribute("camera_override_enabled") == false
	end, 8)
	T.expect(
		"phase21_tune_stop_clears_session_state",
		stopped
			and not TuneMode.isActive()
			and workspace:GetAttribute("AutoTrack_CarTargetSpeed") == nil
			and (stateFolder:GetAttribute("tune_last_pass_json") or "") == ""
			and (stateFolder:GetAttribute("tune_last_batch_json") or "") == "",
		HttpService:JSONEncode({
			active = stateFolder:GetAttribute("tune_mode_active"),
			camera = stateFolder:GetAttribute("camera_override_enabled"),
			speed = workspace:GetAttribute("AutoTrack_CarTargetSpeed"),
			last_pass = stateFolder:GetAttribute("tune_last_pass_json"),
			last_batch = stateFolder:GetAttribute("tune_last_batch_json"),
		})
	)
end

local function testExperimentHarness()
	local comparison = TuneExperiment.compareCandidates({
		{
			label = "flat_control",
			passes = 2,
			state = makeState(3, nil, {}, "None", "None"),
			attr_overrides = {},
		},
		{
			label = "ramp_extreme",
			passes = 2,
			state = makeState(3, "RampJump", {
				ramp_angle = 18,
				ramp_length = 72,
				gap_length = 24,
				landing_length = 24,
			}, "Boost25", "None"),
			attr_overrides = {
				car_target_speed = 160,
			},
		},
	})

	local encoded = HttpService:JSONEncode(comparison)
	T.expect(
		"phase21_experiment_harness_returns_parseable_summary",
		comparison.best ~= nil
			and #comparison.results == 2
			and HttpService:JSONDecode(encoded).best.label == comparison.best.label,
		encoded
	)
	T.expect(
		"phase21_experiment_harness_runs_multiple_passes",
		comparison.results[1].aggregate.pass_count == 2 and comparison.results[2].aggregate.pass_count == 2,
		encoded
	)
	T.expect(
		"phase21_experiment_harness_distinguishes_better_candidate",
		comparison.best.label == "flat_control"
			and comparison.results[1].aggregate.score ~= comparison.results[2].aggregate.score,
		encoded
	)
	T.expect(
		"phase21_experiment_harness_restores_speed_override",
		workspace:GetAttribute("AutoTrack_CarTargetSpeed") == nil,
		tostring(workspace:GetAttribute("AutoTrack_CarTargetSpeed"))
	)
end

local function cleanup()
	if TuneMode.isActive() then
		TuneMode.stop()
		waitUntil(function()
			return not TuneMode.isActive()
		end, 5)
	end
	resetEditableSectors()
end

local function runUnitBody()
	testSectorPath()
	testIsolatedAttempt()
	testIsolatedEntrySnapUsesBaseSpeedOverride()
	testProductionNormalizerStaysConservative()
	testRuntimeIntegrityAndContainmentAttrs()
end

local function runIntegrationBody()
	testTuneLifecycle()
	T.expect(
		"phase21_hotfix_attempts_use_isolated_mode",
		HotfixAgent.attemptMode() == "isolated_sector",
		tostring(HotfixAgent.attemptMode())
	)
end

function TestPhase21.runUnit()
	if not ensureReady() then
		return
	end
	runUnitBody()
	cleanup()
end

function TestPhase21.runIntegration()
	if not ensureReady() then
		return
	end
	runIntegrationBody()
	cleanup()
end

function TestPhase21.run()
	if not ensureReady() then
		return
	end
	runUnitBody()
	runIntegrationBody()
	cleanup()
end

function TestPhase21.runExperiment()
	if not ensureReady() then
		return
	end
	testExperimentHarness()
	cleanup()
	TuneExperiment.restoreCommittedState(3)
end

return TestPhase21
