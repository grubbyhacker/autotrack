-- TestPhase4.luau
-- Smoke tests for pads and the three mechanic builders.
-- Geometry detail tests removed (phase 14 refactor: covered by phase 12 visuals now deleted;
-- behavioral invariants live in phase 5 integrity tests).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local T = require(script.Parent.TestUtils)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)
local VerifierController = require(script.Parent.Parent.Verifier.VerifierController)

type SectorState = Types.SectorState

local TestPhase4 = {}

local TARGET_SECTOR_ID = 4

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
end

local function runLapOnCurrentTrack(stateOverrides: { [number]: SectorState }?): Types.RunResult
	local _, sectors = getSectorMeta(TARGET_SECTOR_ID)
	local waypoints, waypointSectors, sectorKinds = TrackGenerator.getLapPath(sectors, stateOverrides)
	VerifierCar.reset(TrackGenerator.canonicalStart())
	local car = VerifierCar.getPart()
	return VerifierController.runLap(car, waypoints, waypointSectors, sectorKinds, nil)
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

	applyState(makeState(TARGET_SECTOR_ID, "RampJump", {
		ramp_angle = 10,
		ramp_length = 16,
		gap_length = 6,
		landing_length = 24,
	}, "None", "None"))

	local rampLap = runLapOnCurrentTrack()
	T.expect("rampjump_lap_succeeds",
		rampLap.success == true,
		string.format(
			"rampjump lap failed: %s / %s",
			tostring(rampLap.failure and rampLap.failure.type),
			tostring(rampLap.failure and rampLap.failure.detail)
		))

	applyState(makeState(TARGET_SECTOR_ID, "RampJump", {
		ramp_angle = 60,
		ramp_length = 40,
		gap_length = 40,
		landing_length = 4,
	}, "Boost50", "None"))

	local extremeRampLap = runLapOnCurrentTrack()
	T.expect("rampjump_extreme_lap_fails",
		extremeRampLap.success == false,
		"extreme rampjump unexpectedly succeeded")

	resetToFlat()
end

function TestPhase4.runCrestDip()
	if not ensureBaselineOrAbort() then return end

	applyState(makeState(TARGET_SECTOR_ID, "CrestDip", {
		height_or_depth = 5,
		radius = 24,
		sector_length = 24,
	}, "Brake50", "Brake10"))

	local crestLap = runLapOnCurrentTrack()
	T.expect("crestdip_lap_succeeds",
		crestLap.success == true,
		"crestdip lap failed: " .. tostring(crestLap.failure and crestLap.failure.type))

	resetToFlat()
end

function TestPhase4.runChicane()
	if not ensureBaselineOrAbort() then return end

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

function TestPhase4.run()
	TestPhase4.runPads()
	TestPhase4.runRampJump()
	TestPhase4.runCrestDip()
	TestPhase4.runChicane()
end

return TestPhase4
