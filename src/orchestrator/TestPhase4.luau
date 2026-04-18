-- TestPhase4.luau
-- Verifies Phase 4 deliverables: pads plus RampJump, CrestDip, and Chicane
-- geometry with post-baseline validation where the current verifier supports it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)

type SectorState = Types.SectorState

local TestPhase4 = {}

local TARGET_SECTOR_ID = 4

local function makeState(mechanic: Types.Mechanic?, params: Types.SectorParams, ingress: Types.PadValue, egress: Types.PadValue): SectorState
	return {
		sector_id = TARGET_SECTOR_ID,
		mechanic = mechanic,
		params = params,
		pads = {
			ingress = ingress,
			egress = egress,
		},
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
	local child = folder:FindFirstChild(name)
	if child and child:IsA("BasePart") then
		return child
	end
	return nil
end

local function snapshotNamedParts(folder: Folder): { [string]: string }
	local snapshot = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") then
			snapshot[child.Name] = tostring(child.CFrame)
		end
	end
	return snapshot
end

local function localX(frame: CFrame, worldPosition: Vector3): number
	return frame:PointToObjectSpace(worldPosition).X
end

local function localZ(frame: CFrame, worldPosition: Vector3): number
	return frame:PointToObjectSpace(worldPosition).Z
end

local function applyState(state: SectorState)
	local sector = getSectorMeta(state.sector_id)
	SectorApplier.apply(state, sector.entry, sector.exit)
end

local function resetToFlat()
	applyState(makeState(nil, {}, "None", "None"))
	VerifierCar.reset(TrackGenerator.canonicalStart())
end

local function runLapOnCurrentTrack(stateOverrides: { [number]: SectorState }?): Types.RunResult
	local _, sectors = getSectorMeta(TARGET_SECTOR_ID)
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors, stateOverrides)
	VerifierCar.reset(TrackGenerator.canonicalStart())
	local car = VerifierCar.getPart()
	return VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, nil)
end

local function waitForBaseline(): (boolean, number?)
	local deadline = os.clock() + 45
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
		print("[TEST] Proceeding without boot baseline")
		return true
	end

	local baselineOk, baselineTime = waitForBaseline()
	T.expect(
		"baseline_control_still_complete",
		baselineOk and type(baselineTime) == "number" and baselineTime > 0,
		"baseline lap did not complete successfully before phase4 tests"
	)
	if not baselineOk then
		resetToFlat()
		return false
	end
	return true
end

function TestPhase4.runPads()
	if not ensureBaselineOrAbort() then
		return
	end

	local folder = getSectorFolder(TARGET_SECTOR_ID)

	local padState = makeState(nil, {}, "Boost", "Brake")
	applyState(padState)
	local ingressPad = getPart(folder, "IngressPad")
	local egressPad = getPart(folder, "EgressPad")
	T.expect(
		"pads_boost_and_brake_create_expected_named_parts",
		ingressPad ~= nil and egressPad ~= nil
			and ingressPad:GetAttribute("PadType") == "Boost10"
			and egressPad:GetAttribute("PadType") == "Brake10",
		"expected ingress boost and egress brake pads"
	)

	local padLap = runLapOnCurrentTrack()
	T.expect(
		"pads_apply_does_not_break_traversal",
		padLap.success == true,
		"pad-only lap failed: " .. tostring(padLap.failure and padLap.failure.type)
	)

	local noPadState = makeState(nil, {}, "None", "None")
	applyState(noPadState)
	T.expect(
		"pads_none_creates_no_parts",
		getPart(folder, "IngressPad") == nil and getPart(folder, "EgressPad") == nil,
		"pad parts remained after applying None/None"
	)

	local replacePadState = makeState(nil, {}, "Brake", "Boost")
	applyState(replacePadState)
	local replacedIngressPad = getPart(folder, "IngressPad")
	local replacedEgressPad = getPart(folder, "EgressPad")
	T.expect(
		"pads_reapply_replaces_stale_parts",
		replacedIngressPad ~= nil and replacedEgressPad ~= nil
			and replacedIngressPad:GetAttribute("PadType") == "Brake10"
			and replacedEgressPad:GetAttribute("PadType") == "Boost10",
		"pad reapply did not replace stale parts"
	)

	resetToFlat()
end

function TestPhase4.runRampJump()
	if not ensureBaselineOrAbort() then
		return
	end

	local folder = getSectorFolder(TARGET_SECTOR_ID)
	local _, sectors = getSectorMeta(TARGET_SECTOR_ID)
	local targetSector = nil
	for _, sector in ipairs(sectors) do
		if sector.id == TARGET_SECTOR_ID then
			targetSector = sector
			break
		end
	end
	assert(targetSector ~= nil, "target sector missing for rampjump tests")

	local rampState = makeState("RampJump", {
		ramp_angle = 10,
		ramp_length = 16,
		gap_length = 6,
		landing_length = 24,
	}, "None", "None")
	applyState(rampState)

	local ramp = getPart(folder, "Ramp")
	local landing = getPart(folder, "Landing")
	local entryFlat = getPart(folder, "EntryFlat")
	local exitFlat = getPart(folder, "ExitFlat")
	T.expect(
		"rampjump_build_creates_ramp_and_landing",
		ramp ~= nil and landing ~= nil and entryFlat ~= nil and exitFlat ~= nil,
		"expected EntryFlat, Ramp, Landing, and ExitFlat parts"
	)

	T.expect(
		"rampjump_centered_with_balanced_runouts",
		entryFlat ~= nil and exitFlat ~= nil and math.abs(entryFlat.Size.Z - exitFlat.Size.Z) < 0.01,
		string.format(
			"entry=%.2f exit=%.2f",
			entryFlat and entryFlat.Size.Z or -1,
			exitFlat and exitFlat.Size.Z or -1
		)
	)

	T.expect(
		"rampjump_ramp_tilt_is_positive",
		ramp ~= nil and ramp.CFrame.LookVector.Y > 0.05,
		"ramp was not tilted upward"
	)

	local rampLap = runLapOnCurrentTrack()
	T.expect(
		"rampjump_second_lap_completes",
		rampLap.success == true,
		"rampjump lap failed: " .. tostring(rampLap.failure and rampLap.failure.type)
	)
	T.expect(
		"rampjump_second_lap_vertical_displacement",
		rampLap.metrics.vertical_displacement > 2.0,
		string.format(
			"airborne=%s air_distance=%.2f vertical_displacement=%.2f",
			tostring(rampLap.metrics.airborne),
			rampLap.metrics.air_distance,
			rampLap.metrics.vertical_displacement
		)
	)
	T.expect(
		"rampjump_second_lap_reacquired",
		rampLap.metrics.reacquired == true,
		"rampjump did not reacquire after landing"
	)

	applyState(makeState(nil, {}, "None", "None"))
	local restoredBaseline = getPart(folder, string.format("Sector_%02d_Straight", TARGET_SECTOR_ID))
	T.expect(
		"rampjump_flat_reapply_restores_baseline",
		restoredBaseline ~= nil and #folder:GetChildren() == 1,
		string.format("expected restored baseline after flat reapply; childCount=%d", #folder:GetChildren())
	)

	local ok, err = pcall(function()
		SectorApplier.apply(makeState("RampJump", {
			ramp_angle = 10,
			ramp_length = 60,
			gap_length = 40,
			landing_length = 30,
		}, "None", "None"), targetSector.entry, targetSector.exit)
	end)
	T.expect(
		"rampjump_invalid_length_errors",
		not ok and string.find(tostring(err), "geometry exceeds STRAIGHT_LENGTH", 1, true) ~= nil,
		"expected invalid rampjump length to error"
	)

	resetToFlat()
end

function TestPhase4.runCrestDip()
	if not ensureBaselineOrAbort() then
		return
	end

	local folder = getSectorFolder(TARGET_SECTOR_ID)
	local _, sectors = getSectorMeta(TARGET_SECTOR_ID)
	local targetSector = nil
	for _, sector in ipairs(sectors) do
		if sector.id == TARGET_SECTOR_ID then
			targetSector = sector
			break
		end
	end
	assert(targetSector ~= nil, "target sector missing for crestdip tests")

	local crestState = makeState("CrestDip", {
		height_or_depth = 4,
		radius = 60,
		sector_length = 50,
	}, "None", "None")
	applyState(crestState)
	local crest01 = getPart(folder, "Crest_01")
	local crest06 = getPart(folder, "Crest_06")
	local crestEntryFlat = getPart(folder, "EntryFlat")
	local crestExitFlat = getPart(folder, "ExitFlat")
	T.expect(
		"crestdip_crest_builds_curved_segments",
		crest01 ~= nil and crest06 ~= nil and crestEntryFlat ~= nil and crestExitFlat ~= nil and #folder:GetChildren() == 8,
		"expected EntryFlat, six crest curve segments, and ExitFlat"
	)
	T.expect(
		"crestdip_centered_with_balanced_runouts",
		crestEntryFlat ~= nil and crestExitFlat ~= nil and math.abs(crestEntryFlat.Size.Z - crestExitFlat.Size.Z) < 0.01,
		string.format(
			"entry=%.2f exit=%.2f",
			crestEntryFlat and crestEntryFlat.Size.Z or -1,
			crestExitFlat and crestExitFlat.Size.Z or -1
		)
	)

	local crestLap = runLapOnCurrentTrack()
	T.expect(
		"crestdip_second_lap_completes",
		crestLap.success == true,
		"crestdip lap failed: " .. tostring(crestLap.failure and crestLap.failure.type)
	)
	T.expect(
		"crestdip_second_lap_vertical_displacement",
		crestLap.metrics.vertical_displacement > Constants.CRESTDIP_MIN_VERTICAL_DISPLACEMENT,
		string.format("vertical_displacement=%.2f", crestLap.metrics.vertical_displacement)
	)
	T.expect(
		"crestdip_second_lap_follows_curve",
		crestLap.metrics.vertical_displacement > 3.5,
		string.format("path did not track cosine; vertical_displacement=%.2f", crestLap.metrics.vertical_displacement)
	)
	T.expect(
		"crestdip_second_lap_reacquired",
		crestLap.metrics.reacquired == true,
		"crestdip did not maintain/reacquire guidance"
	)

	applyState(makeState("CrestDip", {
		height_or_depth = -4,
		radius = 60,
		sector_length = 50,
	}, "None", "None"))
	local dip01 = getPart(folder, "Dip_01")
	local dip06 = getPart(folder, "Dip_06")
	local dipEntryFlat = getPart(folder, "EntryFlat")
	local dipExitFlat = getPart(folder, "ExitFlat")
	T.expect(
		"crestdip_dip_builds_curved_segments",
		dip01 ~= nil and dip06 ~= nil and dipEntryFlat ~= nil and dipExitFlat ~= nil and #folder:GetChildren() == 8,
		"expected EntryFlat, six dip curve segments, and ExitFlat"
	)

	local crestOk, crestErr = pcall(function()
		SectorApplier.apply(makeState("CrestDip", {
			height_or_depth = 4,
			radius = 60,
			sector_length = Constants.STRAIGHT_LENGTH + 1,
		}, "None", "None"), targetSector.entry, targetSector.exit)
	end)
	T.expect(
		"crestdip_illegal_length_errors",
		not crestOk and string.find(tostring(crestErr), "sector_length exceeds STRAIGHT_LENGTH", 1, true) ~= nil,
		"expected invalid crestdip length to error"
	)
	local baselineAfterError = getPart(folder, string.format("Sector_%02d_Straight", TARGET_SECTOR_ID))
	T.expect(
		"crestdip_failed_apply_preserves_baseline",
		baselineAfterError ~= nil and #folder:GetChildren() == 1,
		string.format("expected preserved baseline after failed apply; childCount=%d", #folder:GetChildren())
	)

	resetToFlat()
end

function TestPhase4.runChicane()
	if not ensureBaselineOrAbort() then
		return
	end

	local chicaneSectorId = 3
	local function makeChicaneState(mechanic: Types.Mechanic?, params: Types.SectorParams, ingress: Types.PadValue, egress: Types.PadValue): SectorState
		return {
			sector_id = chicaneSectorId,
			mechanic = mechanic,
			params = params,
			pads = {
				ingress = ingress,
				egress = egress,
			},
			version = 0,
		}
	end

	local folder = getSectorFolder(chicaneSectorId)
	local _, sectors = getSectorMeta(chicaneSectorId)
	local targetSector = nil
	for _, sector in ipairs(sectors) do
		if sector.id == chicaneSectorId then
			targetSector = sector
			break
		end
	end
	assert(targetSector ~= nil, "target sector missing for chicane tests")

	local chicaneState = makeChicaneState("Chicane", {
		amplitude = 6,
		transition_length = 24,
		corridor_width = 16,
	}, "None", "None")
	applyState(chicaneState)
	local expectedChicaneNames = {
		ChicEntryFlat = true,
		ChicEntry = true,
		ChicTurn1_01 = true,
		ChicTurn1_02 = true,
		ChicTurn1_03 = true,
		ChicTurn1_04 = true,
		ChicTurn2_01 = true,
		ChicTurn2_02 = true,
		ChicTurn2_03 = true,
		ChicTurn2_04 = true,
		ChicTurn3_01 = true,
		ChicTurn3_02 = true,
		ChicTurn3_03 = true,
		ChicTurn3_04 = true,
		ChicExit = true,
		ChicExitFlat = true,
	}
	local chicaneNamesOk = #folder:GetChildren() == 16
	for _, child in ipairs(folder:GetChildren()) do
		if not expectedChicaneNames[child.Name] then
			chicaneNamesOk = false
			break
		end
	end
	T.expect(
		"chicane_build_creates_expected_segment_set",
		chicaneNamesOk,
		"expected compound-corner chicane segment set"
	)

	local hasPositiveOffset = false
	local hasNegativeOffset = false
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") and string.find(child.Name, "ChicTurn", 1, true) ~= nil then
			local x = localX(targetSector.entry, child.Position)
			if x > 2 then
				hasPositiveOffset = true
			elseif x < -2 then
				hasNegativeOffset = true
			end
		end
	end
	T.expect(
		"chicane_geometry_uses_both_lateral_sides",
		hasPositiveOffset and hasNegativeOffset,
		"expected chicane path to visit both lateral sides of the centerline"
	)

	local entryPart = getPart(folder, "ChicEntry")
	local exitPart = getPart(folder, "ChicExit")
	T.expect(
		"chicane_entry_and_exit_centerlines_preserved",
		entryPart ~= nil and exitPart ~= nil
			and math.abs(localX(targetSector.entry, entryPart.Position)) < 0.5
			and math.abs(localX(targetSector.entry, exitPart.Position)) < 0.5
			and math.abs(entryPart.CFrame.LookVector:Dot(targetSector.entry.RightVector)) < 0.05
			and math.abs(exitPart.CFrame.LookVector:Dot(targetSector.entry.RightVector)) < 0.05,
		"expected centered straight entry/exit alignment"
	)

	local exitFlatPart = getPart(folder, "ChicExitFlat")
	local entryFlatPart = getPart(folder, "ChicEntryFlat")
	T.expect(
		"chicane_centered_with_balanced_runouts",
		entryFlatPart ~= nil
			and exitFlatPart ~= nil
			and math.abs(localX(targetSector.entry, entryFlatPart.Position)) < 0.5
			and math.abs(localX(targetSector.entry, exitFlatPart.Position)) < 0.5
			and math.abs(entryFlatPart.Size.Z - exitFlatPart.Size.Z) < 0.01,
		string.format(
			"entry=%.2f exit=%.2f",
			entryFlatPart and entryFlatPart.Size.Z or -1,
			exitFlatPart and exitFlatPart.Size.Z or -1
		)
	)

	local beforeSnapshot = snapshotNamedParts(folder)
	applyState(chicaneState)
	local afterSnapshot = snapshotNamedParts(folder)
	local deterministic = true
	for name, cf in pairs(beforeSnapshot) do
		if afterSnapshot[name] ~= cf then
			deterministic = false
			break
		end
	end
	for name in pairs(afterSnapshot) do
		if beforeSnapshot[name] == nil then
			deterministic = false
			break
		end
	end
	T.expect(
		"chicane_apply_is_deterministic",
		deterministic,
		"reapplying chicane changed named part transforms"
	)

	local waypoints, waypointSectorIds = TrackGenerator.getLapPath(sectors, {
		[chicaneSectorId] = chicaneState,
	})
	local sectorWaypointZs = {}
	for index, waypoint in ipairs(waypoints) do
		if waypointSectorIds[index] == chicaneSectorId then
			table.insert(sectorWaypointZs, math.abs(localZ(targetSector.entry, waypoint.Position)))
		end
	end
	T.expect(
		"chicane_path_waypoints_cover_centered_runouts",
		#sectorWaypointZs >= 4
			and sectorWaypointZs[1] > 0
			and sectorWaypointZs[#sectorWaypointZs] >= Constants.STRAIGHT_LENGTH - 0.01,
		table.concat(sectorWaypointZs, ",")
	)

	local chicaneOk, chicaneErr = pcall(function()
		SectorApplier.apply(makeChicaneState("Chicane", {
			amplitude = 12,
			transition_length = 30,
			corridor_width = 14,
		}, "None", "None"), targetSector.entry, targetSector.exit)
	end)
	T.expect(
		"chicane_illegal_total_length_errors",
		not chicaneOk and string.find(tostring(chicaneErr), "geometry exceeds STRAIGHT_LENGTH", 1, true) ~= nil,
		"expected invalid chicane length to error"
	)

	applyState(makeChicaneState(nil, {}, "None", "None"))
	VerifierCar.reset(TrackGenerator.canonicalStart())
end

function TestPhase4.run()
	TestPhase4.runPads()
	TestPhase4.runRampJump()
	TestPhase4.runCrestDip()
	TestPhase4.runChicane()
end

return TestPhase4
