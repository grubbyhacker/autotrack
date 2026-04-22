-- TestPhase4.luau
-- Smoke tests for pads and the three mechanic builders.
-- Geometry detail tests removed (phase 14 refactor: covered by phase 12 visuals now deleted;
-- behavioral invariants live in phase 5 integrity tests).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local TestSession = require(script.Parent.TestSession)
local UIState = require(script.Parent.UIState)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local ChicanePath = require(script.Parent.Parent.Mechanics.ChicanePath)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)

type SectorState = Types.SectorState

local TestPhase4 = {}

local TARGET_SECTOR_ID = 4
local CHICANE_CAPTURE_SECTOR_ID = 3
local CHICANE_CAPTURE_SETTLE_SECONDS = 2
local CHICANE_CAPTURE_FIELD_OF_VIEW = 50

local function makeState(sectorId: number, mechanic: Types.Mechanic?, params: Types.SectorParams, ingress: Types.PadValue, egress: Types.PadValue): SectorState
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		params = params,
		pads = { ingress = ingress, egress = egress },
		version = 0,
	}
end

local function getSectorMeta(sectorId: number)
	local sectors = TrackGenerator.generate()
	for _, sector in ipairs(sectors) do
		if sector.id == sectorId then
			return sector, sectors
		end
	end
	error("sector not found: " .. tostring(sectorId))
end

local function getSectorFolder(sectorId: number): Folder
	local track = workspace:FindFirstChild("Track")
	assert(track, "Track folder missing")
	local folder = track:FindFirstChild(string.format("Sector_%02d", sectorId))
	assert(folder and folder:IsA("Folder"), "sector folder missing")
	return folder
end

local function getPart(folder: Folder, name: string): BasePart?
	local child = folder:FindFirstChild(name, true)
	if child and child:IsA("BasePart") then return child end
	return nil
end

local function applyState(state: SectorState)
	local sector = getSectorMeta(state.sector_id)
	SectorApplier.apply(state, sector.entry, sector.exit)
end

local function resetToFlat()
	applyState(makeState(TARGET_SECTOR_ID, nil, {}, "None", "None"))
	VerifierCar.reset(TrackGenerator.canonicalStart())
	UIState.clearCameraOverride()
end

local function clearEditableSectors()
	local sectors = TrackGenerator.generate()
	for _, sector in ipairs(sectors) do
		if sector.kind == "Straight" then
			SectorApplier.apply(makeState(sector.id, nil, {}, "None", "None"), sector.entry, sector.exit)
		end
	end
end

local function countNamedChildren(parent: Instance, prefix: string): number
	local count = 0
	for _, child in ipairs(parent:GetChildren()) do
		if string.sub(child.Name, 1, #prefix) == prefix then
			count += 1
		end
	end
	return count
end

local function runLapOnCurrentTrack(stateOverrides: { [number]: SectorState }?): Types.RunResult
	local _, sectors = getSectorMeta(TARGET_SECTOR_ID)
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors, stateOverrides)
	VerifierCar.reset(TrackGenerator.canonicalStart())
	local car = VerifierCar.getPart()
	return VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, nil)
end

local function toSectorLocal(entryFrame: CFrame, worldPoint: Vector3): Vector3
	local localPoint = entryFrame:PointToObjectSpace(worldPoint)
	return Vector3.new(localPoint.X, localPoint.Y, -localPoint.Z)
end

local function waitForBaseline(): (boolean, number?)
	local deadline = os.clock() + 60
	while os.clock() < deadline do
		local lapDone = workspace:GetAttribute("AutoTrack_BaselineLapDone")
		local lapTime = workspace:GetAttribute("AutoTrack_BaselineLapTime")
		if lapDone ~= nil and lapTime ~= nil then
			return lapDone == true, lapTime
		end
		task.wait(0.25)
	end
	return false, nil
end

local function ensureBaselineOrAbort(): boolean
	if workspace:GetAttribute("AutoTrack_BootBaselineSkipped") == true then
		return true
	end
	local baselineOk = waitForBaseline()
	T.expect("baseline_control_still_complete", baselineOk, "baseline lap did not complete before phase4 tests")
	if not baselineOk then
		resetToFlat()
		return false
	end
	return true
end

function TestPhase4.runPads()
	if not ensureBaselineOrAbort() then return end

	local folder = getSectorFolder(TARGET_SECTOR_ID)

	-- Standard pads create expected parts
	applyState(makeState(TARGET_SECTOR_ID, nil, {}, "Boost10", "Brake10"))
	local ingressPad = getPart(folder, "IngressPad")
	local egressPad = getPart(folder, "EgressPad")
	T.expect("pads_boost_and_brake_create_parts",
		ingressPad ~= nil and egressPad ~= nil
			and ingressPad:GetAttribute("PadType") == "Boost10"
			and egressPad:GetAttribute("PadType") == "Brake10",
		"expected Boost10/Brake10 pad parts")

	-- Pad-only lap succeeds
	local padLap = runLapOnCurrentTrack()
	T.expect("pads_apply_does_not_break_traversal",
		padLap.success == true,
		"pad-only lap failed: " .. tostring(padLap.failure and padLap.failure.type))

	-- None removes parts
	applyState(makeState(TARGET_SECTOR_ID, nil, {}, "None", "None"))
	T.expect("pads_none_creates_no_parts",
		getPart(folder, "IngressPad") == nil and getPart(folder, "EgressPad") == nil,
		"pad parts remained after None/None")

	-- Boost50 / Brake50 are valid and create parts
	applyState(makeState(TARGET_SECTOR_ID, nil, {}, "Boost50", "Brake50"))
	local ingress50 = getPart(folder, "IngressPad")
	local egress50 = getPart(folder, "EgressPad")
	T.expect("pads_boost50_brake50_create_parts",
		ingress50 ~= nil and egress50 ~= nil
			and ingress50:GetAttribute("PadType") == "Boost50"
			and egress50:GetAttribute("PadType") == "Brake50",
		"expected Boost50/Brake50 pad parts")

	resetToFlat()
end

function TestPhase4.runRampJump()
	if not ensureBaselineOrAbort() then return end

	local rampState = makeState(TARGET_SECTOR_ID, "RampJump", {
		ramp_angle = 4,
		ramp_length = 24,
		gap_length = 2,
		landing_length = 34,
	}, "Brake25", "Brake10")
	applyState(rampState)

	local rampLap = runLapOnCurrentTrack({ [TARGET_SECTOR_ID] = rampState })
	T.expect("rampjump_lap_progresses",
		rampLap.success == true
			or (
				rampLap.metrics.target_entered == true
				and (rampLap.metrics.target_progress or 0) >= 0.35
			),
		string.format(
			"rampjump lap failed: %s / %s progress=%.2f",
			tostring(rampLap.failure and rampLap.failure.type),
			tostring(rampLap.failure and rampLap.failure.detail),
			rampLap.metrics.target_progress or 0
		))

	local extremeRampState = makeState(TARGET_SECTOR_ID, "RampJump", {
		ramp_angle = 60,
		ramp_length = 40,
		gap_length = 40,
		landing_length = 4,
	}, "Boost50", "None")
	applyState(extremeRampState)

	local extremeRampLap = runLapOnCurrentTrack({ [TARGET_SECTOR_ID] = extremeRampState })
	T.expect("rampjump_extreme_lap_fails",
		extremeRampLap.success == false,
		"extreme rampjump unexpectedly succeeded")

	resetToFlat()
end

function TestPhase4.runCrestDip()
	if not ensureBaselineOrAbort() then return end

	local crestState = makeState(TARGET_SECTOR_ID, "CrestDip", {
		height_or_depth = 4,
		radius = 24,
		sector_length = 40,
	}, "Brake25", "Brake10")
	applyState(crestState)

	local crestLap = runLapOnCurrentTrack({ [TARGET_SECTOR_ID] = crestState })
	T.expect("crestdip_lap_succeeds",
		crestLap.success == true,
		"crestdip lap failed: " .. tostring(crestLap.failure and crestLap.failure.type))

	local crestSector = getSectorMeta(TARGET_SECTOR_ID)
	local crestWaypoints = TrackGenerator.getSectorPath(crestSector, crestState)
	local crestExitLocal = nil
	local maxCrestWaypointY = -math.huge
	for _, waypoint in ipairs(crestWaypoints) do
		maxCrestWaypointY = math.max(maxCrestWaypointY, waypoint.Position.Y)
	end
	if crestWaypoints[#crestWaypoints] ~= nil then
		crestExitLocal = toSectorLocal(crestSector.entry, crestWaypoints[#crestWaypoints].Position)
	end
	local rideY = Constants.TRACK_THICKNESS + (Constants.CAR_HEIGHT * 0.5)
	T.expect(
		"crestdip_sector_path_reaches_exit",
		crestExitLocal ~= nil
			and math.abs(crestExitLocal.Z - Constants.STRAIGHT_LENGTH) <= 0.5
			and math.abs(crestWaypoints[#crestWaypoints].Position.Y - rideY) <= 0.25
			and maxCrestWaypointY > rideY + 1,
		crestExitLocal and string.format(
			"last=(%.2f, %.2f, %.2f) maxY=%.2f",
			crestExitLocal.X,
			crestExitLocal.Y,
			crestExitLocal.Z,
			maxCrestWaypointY
		) or "no crest waypoints built"
	)

	resetToFlat()
end

function TestPhase4.runChicane()
	if not ensureBaselineOrAbort() then return end

	local wavePoints = ChicanePath.buildLocalCenterlinePoints(6, 18, 64)
	local coarsePoints = ChicanePath.buildLocalCenterlinePoints(6, 18)
	local visualPoints = ChicanePath.buildLocalVisualCenterlinePoints(6, 18)
	local positivePeak = nil
	local negativePeak = nil
	local zeroBetweenPeaks = false
	for _, point in ipairs(wavePoints) do
		if positivePeak == nil or point.X > positivePeak.X then
			positivePeak = point
		end
		if negativePeak == nil or point.X < negativePeak.X then
			negativePeak = point
		end
	end
	for _, point in ipairs(wavePoints) do
		if positivePeak ~= nil and negativePeak ~= nil
			and point.Z > positivePeak.Z and point.Z < negativePeak.Z
			and math.abs(point.X) <= 0.2 then
			zeroBetweenPeaks = true
			break
		end
	end
	T.expect("chicane_wave_starts_and_ends_centered",
		math.abs(wavePoints[1].X) <= 1e-4 and math.abs(wavePoints[#wavePoints].X) <= 1e-4,
		"expected chicane wave to start/end on centerline")
	T.expect("chicane_wave_reaches_both_extremes",
		positivePeak ~= nil and negativePeak ~= nil and positivePeak.X >= 5.9 and negativePeak.X <= -5.9,
		string.format("expected peaks near +/-6, got +%.2f / %.2f", positivePeak and positivePeak.X or 0, negativePeak and negativePeak.X or 0))
	T.expect("chicane_wave_peak_spacing_matches_transition_length",
		positivePeak ~= nil and negativePeak ~= nil and math.abs((negativePeak.Z - positivePeak.Z) - 18) <= 0.5,
		string.format("expected peak spacing near 18, got %.2f", (negativePeak and positivePeak) and (negativePeak.Z - positivePeak.Z) or -1))
	T.expect("chicane_wave_crosses_zero_between_extremes",
		zeroBetweenPeaks == true,
		"expected smooth wave to cross centerline between the two peaks")
	T.expect("chicane_visual_overlay_is_denser_than_collision_path",
		#visualPoints > #coarsePoints * 3,
		string.format("expected visual path substantially denser than collision path, got %d vs %d", #visualPoints, #coarsePoints))

	local chicaneSectorId = 3
	local _, sectors = getSectorMeta(chicaneSectorId)
	local chicaneState = {
		sector_id = chicaneSectorId,
		mechanic = "Chicane",
		params = { amplitude = 4, transition_length = 24, corridor_width = 16 },
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}
	local targetSector = nil
	for _, sector in ipairs(sectors) do
		if sector.id == chicaneSectorId then
			targetSector = sector
			break
		end
	end
	assert(targetSector, "chicane sector missing")
	SectorApplier.apply(chicaneState, targetSector.entry, targetSector.exit)

	local chicaneWaypoints = TrackGenerator.getSectorPath(targetSector, chicaneState)
	local chicaneExitLocal = nil
	local maxAbsLateral = 0
	for _, waypoint in ipairs(chicaneWaypoints) do
		local localPoint = toSectorLocal(targetSector.entry, waypoint.Position)
		maxAbsLateral = math.max(maxAbsLateral, math.abs(localPoint.X))
	end
	if chicaneWaypoints[#chicaneWaypoints] ~= nil then
		chicaneExitLocal = toSectorLocal(targetSector.entry, chicaneWaypoints[#chicaneWaypoints].Position)
	end
	T.expect(
		"chicane_sector_path_reaches_exit",
		chicaneExitLocal ~= nil
			and math.abs(chicaneExitLocal.Z - Constants.STRAIGHT_LENGTH) <= 0.5
			and math.abs(chicaneExitLocal.X) <= 0.5
			and maxAbsLateral >= 3.5,
		chicaneExitLocal and string.format(
			"last=(%.2f, %.2f, %.2f) maxAbsLateral=%.2f",
			chicaneExitLocal.X,
			chicaneExitLocal.Y,
			chicaneExitLocal.Z,
			maxAbsLateral
		) or "no chicane waypoints built"
	)

	local visualFolder = getSectorFolder(chicaneSectorId):FindFirstChild("Visual")
	assert(visualFolder and visualFolder:IsA("Folder"), "chicane visual folder missing")
	T.expect("chicane_visual_has_no_segmented_edge_lines",
		visualFolder:FindFirstChild("EdgeLine_L_01") == nil and visualFolder:FindFirstChild("EdgeLine_R_01") == nil,
		"expected chicane visual overlay to omit segmented path edge lines")
	T.expect("chicane_visual_has_no_underlay_ribbon",
		visualFolder:FindFirstChild("RoadSurfaceUnderlay_01") == nil,
		"expected chicane visual overlay to omit path underlay ribbon")
	T.expect("chicane_visual_uses_single_surface_ribbon",
		visualFolder:FindFirstChild("RoadSurfaceSeam") == nil and visualFolder:FindFirstChild("RoadSurfaceTop") == nil,
		"expected chicane visual to use one mitered surface ribbon instead of stacked seam folders")
	T.expect("chicane_visual_has_round_join_caps",
		countNamedChildren(visualFolder, "RoadSurfaceJoin_") > 0,
		"expected chicane visual to add explicit join caps at turning vertices")

	local chicaneLap = runLapOnCurrentTrack({ [chicaneSectorId] = chicaneState })
	T.expect("chicane_lap_succeeds",
		chicaneLap.success == true,
		"chicane lap failed: " .. tostring(chicaneLap.failure and chicaneLap.failure.type))

	SectorApplier.apply({
		sector_id = chicaneSectorId,
		mechanic = nil,
		params = {},
		pads = { ingress = "None", egress = "None" },
		version = 0,
	}, targetSector.entry, targetSector.exit)
	VerifierCar.reset(TrackGenerator.canonicalStart())
end

function TestPhase4.runChicaneCapture()
	clearEditableSectors()

	local sector = getSectorMeta(CHICANE_CAPTURE_SECTOR_ID)
	local captureState = makeState(CHICANE_CAPTURE_SECTOR_ID, "Chicane", {
		amplitude = 8,
		transition_length = 20,
		corridor_width = 16,
	}, "None", "None")
	SectorApplier.apply(captureState, sector.entry, sector.exit)
	VerifierCar.reset(TrackGenerator.canonicalStart())

	local straightCenter = sector.entry.Position:Lerp(sector.exit.Position, 0.5)
	local look = sector.entry.LookVector
	local right = sector.entry.RightVector
	local focus = straightCenter + Vector3.yAxis * 3
	local position = focus
		+ right * 54
		+ Vector3.yAxis * 36
		- look * 16

	UIState.setCameraOverride(position, focus, CHICANE_CAPTURE_FIELD_OF_VIEW)
	UIState.setPhase("Capture", "Chicane capture ready")
	task.wait(CHICANE_CAPTURE_SETTLE_SECONDS)

	TestSession.setPayload({
		chicane_capture = {
			sector_id = CHICANE_CAPTURE_SECTOR_ID,
			mechanic = "Chicane",
			params = captureState.params,
			camera = {
				position = { x = position.X, y = position.Y, z = position.Z },
				focus = { x = focus.X, y = focus.Y, z = focus.Z },
				field_of_view = CHICANE_CAPTURE_FIELD_OF_VIEW,
			},
			settle_seconds = CHICANE_CAPTURE_SETTLE_SECONDS,
			manual_hint = "/test phase4_chicane_capture",
		},
	})

	local folder = getSectorFolder(CHICANE_CAPTURE_SECTOR_ID)
	local visualFolder = folder:FindFirstChild("Visual")
	T.expect(
		"chicane_capture_scene_ready",
		visualFolder ~= nil and visualFolder:IsA("Folder"),
		"capture scene missing chicane visual folder"
	)

	local stateFolder = UIState.getStateFolder()
	T.expect(
		"chicane_capture_camera_override_armed",
		stateFolder:GetAttribute("camera_override_enabled") == true
			and stateFolder:GetAttribute("camera_override_fov") == CHICANE_CAPTURE_FIELD_OF_VIEW,
		"capture camera override was not armed"
	)
end

function TestPhase4.run()
	TestPhase4.runPads()
	TestPhase4.runRampJump()
	TestPhase4.runCrestDip()
	TestPhase4.runChicane()
end

return TestPhase4
