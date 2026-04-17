-- RampJumpBuilder.luau
-- Builds RampJump geometry from a SectorState.
-- prd_plan.md §4.1, Phase 4
--
-- Layout (entry → exit, all within the sector bounds):
--   [ingress pad] [ramp] [gap (air)] [landing] [egress pad]
--
-- All physical parts are placed via MCP using the entry CFrame as the
-- local origin.  No script instances are created here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))

type SectorState = Types.SectorState

local RampJumpBuilder = {}

local function worldPoint(entryFrame: CFrame, x: number, y: number, z: number): Vector3
	return entryFrame.Position
		+ entryFrame.RightVector * x
		+ entryFrame.UpVector * y
		+ entryFrame.LookVector * z
end

local function orientedAlongTrack(entryFrame: CFrame, x: number, y: number, z: number, pitch: number): CFrame
	local position = worldPoint(entryFrame, x, y, z)
	local forward = (entryFrame * CFrame.Angles(pitch, 0, 0)).LookVector
	return CFrame.lookAt(position, position + forward)
end

local function getSectorFolder(sector_id: number): Folder
	local name = string.format("Sector_%02d", sector_id)
	local track = workspace:FindFirstChild("Track")
	local folder = track and track:FindFirstChild(name)
	assert(folder, "getSectorFolder: not found: " .. name)
	return folder :: Folder
end

local function makePart(name: string, size: Vector3, cf: CFrame, color: BrickColor, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.CanCollide = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	part.BrickColor = color
	part.Parent = parent
	return part
end

-- Build all physical parts for a RampJump sector.
-- entryFrame: CFrame at the sector entry boundary
-- exitFrame:  CFrame at the sector exit boundary
function RampJumpBuilder.build(state: SectorState, entryFrame: CFrame, exitFrame: CFrame)
	local p = state.params
	assert(p.ramp_angle,     "RampJumpBuilder: missing ramp_angle")
	assert(p.ramp_length,    "RampJumpBuilder: missing ramp_length")
	assert(p.gap_length,     "RampJumpBuilder: missing gap_length")
	assert(p.landing_length, "RampJumpBuilder: missing landing_length")

	local angleRad = math.rad(p.ramp_angle)
	local rampHeight = p.ramp_length * math.tan(angleRad)
	local rampSurfaceLength = p.ramp_length / math.cos(angleRad)
	local totalHorizontal = p.ramp_length + p.gap_length + p.landing_length
	assert(
		totalHorizontal <= Constants.STRAIGHT_LENGTH,
		"RampJumpBuilder: geometry exceeds STRAIGHT_LENGTH (" .. totalHorizontal .. ")"
	)

	local width = Constants.TRACK_WIDTH
	local thickness = Constants.TRACK_THICKNESS
	local folder = getSectorFolder(state.sector_id)

	local rampCF = orientedAlongTrack(entryFrame, 0, rampHeight * 0.5, p.ramp_length * 0.5, angleRad)
	makePart(
		"Ramp",
		Vector3.new(width, thickness, rampSurfaceLength),
		rampCF,
		BrickColor.new("Bright orange"),
		folder
	)

	local landingZ = p.ramp_length + p.gap_length + p.landing_length * 0.5
	local landingCenter = worldPoint(entryFrame, 0, 0, landingZ)
	local landingCF = CFrame.lookAt(landingCenter, landingCenter + entryFrame.LookVector)
	makePart(
		"Landing",
		Vector3.new(width, thickness, p.landing_length),
		landingCF,
		BrickColor.new("Dark stone grey"),
		folder
	)

	local exitFlatLength = Constants.STRAIGHT_LENGTH - totalHorizontal
	if exitFlatLength > 0 then
		local exitFlatZ = totalHorizontal + exitFlatLength * 0.5
		local exitFlatCenter = worldPoint(entryFrame, 0, 0, exitFlatZ)
		local exitFlatCF = CFrame.lookAt(exitFlatCenter, exitFlatCenter + entryFrame.LookVector)
		makePart(
			"ExitFlat",
			Vector3.new(width, thickness, exitFlatLength),
			exitFlatCF,
			BrickColor.new("Medium stone grey"),
			folder
		)
	end
end

return RampJumpBuilder
