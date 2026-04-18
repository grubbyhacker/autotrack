local ReplicatedStorage = game:GetService("ReplicatedStorage")

local T = require(script.Parent.TestUtils)
local TrackGenerator = require(script.Parent.Parent.Track.TrackGenerator)
local SectorApplier = require(script.Parent.Parent.Track.SectorApplier)
local VerifierCar = require(script.Parent.Parent.Verifier.VerifierCar)

local TestPhase12 = {}

local function getSectorFolder(id: number): Folder
	local track = workspace:FindFirstChild("Track")
	assert(track and track:IsA("Folder"), "workspace.Track not found")
	local folder = track:FindFirstChild(string.format("Sector_%02d", id))
	assert(folder and folder:IsA("Folder"), "sector folder missing: " .. tostring(id))
	return folder
end

local function getPart(folder: Folder, name: string): BasePart?
	local child = folder:FindFirstChild(name, true)
	if child and child:IsA("BasePart") then
		return child
	end
	return nil
end

local function makeState(sectorId: number, mechanic, params)
	return {
		sector_id = sectorId,
		mechanic = mechanic,
		params = params or {},
		pads = {
			ingress = "None",
			egress = "None",
		},
		version = 0,
	}
end

function TestPhase12.run()
	local sectors = TrackGenerator.generate()
	local sectorById = {}
	for _, sector in ipairs(sectors) do
		sectorById[sector.id] = sector
	end

	do
		local folder = getSectorFolder(2)
		local shell = getPart(folder, "CellShell")
		local road = getPart(folder, "RoadSurface")
		T.expect(
			"phase12_straight_has_sector_shell",
			shell ~= nil,
			"expected straight sector shell visual"
		)
		T.expect(
			"phase12_straight_has_lane_markings",
			road ~= nil
				and road:FindFirstChild("CenterDash_120") ~= nil
				and road:FindFirstChild("EdgeLine_L") ~= nil
				and road:FindFirstChild("EdgeLine_R") ~= nil,
			"expected straight lane markings"
		)
	end

	do
		local cornerPart = getPart(getSectorFolder(1), "Sector_01_Corner")
		local cornerRoad = getPart(getSectorFolder(1), "RoadSurface_01")
		local cornerShell = getPart(getSectorFolder(1), "CellShell")
		T.expect(
			"phase12_corner_has_lane_lines",
			cornerPart ~= nil
				and getPart(getSectorFolder(1), "CornerLineInner_01") ~= nil
				and getPart(getSectorFolder(1), "CornerLineOuter_01") ~= nil,
			"expected corner lane-line visuals"
		)
		T.expect(
			"phase12_corner_has_sandstone_cell",
			cornerShell ~= nil and cornerShell.Material == Enum.Material.Concrete,
			"expected corner non-road area to match the sandstone corner cell"
		)
		T.expect(
			"phase12_corner_has_visible_road_arc",
			cornerRoad ~= nil and cornerRoad:IsA("BasePart"),
			"expected corner road arc visuals"
		)
		T.expect(
			"phase12_corner_road_is_flush",
			cornerPart ~= nil and cornerRoad ~= nil and cornerRoad:IsA("BasePart")
				and cornerPart.CFrame:PointToObjectSpace(cornerRoad.Position).Y < (cornerPart.Size.Y * 0.5 + 0.1),
			"expected corner road arc to sit flush, not visibly stepped above the sector"
		)
	end

	do
		local car = workspace:FindFirstChild("VerifierCar")
		T.expect(
			"phase12_verifier_root_is_still_basepart",
			car ~= nil and car:IsA("BasePart"),
			"VerifierCar root must remain a BasePart"
		)
		T.expect(
			"phase12_verifier_has_f1_visual_children",
			car ~= nil
				and car:FindFirstChild("FrontWing") ~= nil
				and car:FindFirstChild("RearWingMain") ~= nil
				and car:FindFirstChild("WheelFront_L") ~= nil
				and car:FindFirstChild("WheelRear_R") ~= nil,
			"expected welded F1-style body visuals"
		)
	end

	do
		local sector = sectorById[2]
		assert(sector ~= nil, "sector 2 metadata missing")
		SectorApplier.apply(makeState(2, "RampJump", {
			ramp_angle = 14,
			ramp_length = 16,
			gap_length = 8,
			landing_length = 20,
		}), sector.entry, sector.exit)

		local ramp = getPart(getSectorFolder(2), "Ramp")
		T.expect(
			"phase12_rampjump_has_supports",
			ramp ~= nil
				and ramp:FindFirstChild("RampSupport_0_1") ~= nil
				and ramp:FindFirstChild("RampSupport_1_1") ~= nil,
			"expected ramp supports"
		)
		T.expect(
			"phase12_rampjump_has_chevrons",
			ramp ~= nil
				and ramp:FindFirstChild("RampChevron_1_1") ~= nil
				and ramp:FindFirstChild("RampChevron_1_2") ~= nil
				and ramp:FindFirstChild("RampChevron_4_1") ~= nil
				and ramp:FindFirstChild("RampChevron_4_2") ~= nil,
			"expected ramp chevron visuals"
		)
		SectorApplier.apply(makeState(2, nil, {}), sector.entry, sector.exit)
	end

	do
		local sector = sectorById[3]
		assert(sector ~= nil, "sector 3 metadata missing")
		SectorApplier.apply(makeState(3, "Chicane", {
			amplitude = 6,
			transition_length = 20,
			corridor_width = 14,
		}), sector.entry, sector.exit)

		local entryPart = getPart(getSectorFolder(3), "ChicEntry")
		local chicaneShell = getPart(getSectorFolder(3), "StraightShell")
		T.expect(
			"phase12_chicane_uses_road_material",
			entryPart ~= nil and entryPart.Material == Enum.Material.Asphalt,
			"expected chicane segments to be asphalt"
		)
		T.expect(
			"phase12_chicane_has_curbs",
			entryPart ~= nil and entryPart:FindFirstChild("Curb_L") ~= nil and entryPart:FindFirstChild("Curb_R") ~= nil,
			"expected chicane curb visuals"
		)
		T.expect(
			"phase12_chicane_has_alternating_stripes",
			entryPart ~= nil and entryPart:FindFirstChild("Stripe_01_1") ~= nil and entryPart:FindFirstChild("Stripe_01_2") ~= nil,
			"expected chicane stripe visuals"
		)
		T.expect(
			"phase12_chicane_has_shell",
			chicaneShell ~= nil and chicaneShell:IsA("BasePart"),
			"expected chicane non-road shell visual"
		)
		SectorApplier.apply(makeState(3, nil, {}), sector.entry, sector.exit)
	end

	VerifierCar.reset(TrackGenerator.canonicalStart())
end

return TestPhase12
