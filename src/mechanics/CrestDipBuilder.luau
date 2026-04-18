-- CrestDipBuilder.luau
-- Builds CrestDip (vertical crest or dip) geometry from a SectorState.
-- prd_plan.md §4.3, Phase 4
--
-- height_or_depth > 0 → crest (rises above baseline)
-- height_or_depth < 0 → dip  (drops below baseline)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local TrackVisuals = require(script.Parent.Parent.Track.TrackVisuals)

type SectorState = Types.SectorState

local CrestDipBuilder = {}
local CURVE_SEGMENTS = 6

local function worldPoint(entryFrame: CFrame, point: Vector3): Vector3
	return entryFrame.Position
		+ entryFrame.RightVector * point.X
		+ entryFrame.UpVector * point.Y
		+ entryFrame.LookVector * point.Z
end

local function getSectorFolder(sector_id: number): Folder
	return TrackVisuals.getCollisionFolder(sector_id)
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
	TrackVisuals.styleRoadPiece(part)
	return part
end

local function makeSegment(
	name: string,
	startPoint: Vector3,
	endPoint: Vector3,
	entryFrame: CFrame,
	color: BrickColor,
	parent: Instance
): Part
	local delta = endPoint - startPoint
	local length = delta.Magnitude
	assert(length > 0, "CrestDipBuilder.makeSegment: zero-length segment")
	local worldStart = worldPoint(entryFrame, startPoint)
	local worldEnd = worldPoint(entryFrame, endPoint)
	local center = worldStart:Lerp(worldEnd, 0.5)
	local cf = CFrame.lookAt(center, center + (worldEnd - worldStart).Unit)
	return makePart(
		name,
		Vector3.new(Constants.TRACK_WIDTH, Constants.TRACK_THICKNESS, length),
		cf,
		color,
		parent
	)
end

local function makeFlatRunout(
	name: string,
	entryFrame: CFrame,
	startZ: number,
	length: number,
	color: BrickColor,
	parent: Instance
)
	if length <= 0 then
		return
	end

	local center = worldPoint(entryFrame, Vector3.new(0, 0, startZ + length * 0.5))
	local cf = CFrame.lookAt(center, center + entryFrame.LookVector)
	makePart(
		name,
		Vector3.new(Constants.TRACK_WIDTH, Constants.TRACK_THICKNESS, length),
		cf,
		color,
		parent
	)
end

function CrestDipBuilder.build(state: SectorState, entryFrame: CFrame, exitFrame: CFrame)
	local p = state.params
	assert(p.height_or_depth, "CrestDipBuilder: missing height_or_depth")
	assert(p.radius,          "CrestDipBuilder: missing radius")
	assert(p.sector_length,   "CrestDipBuilder: missing sector_length")
	assert(
		p.sector_length <= Constants.STRAIGHT_LENGTH,
		"CrestDipBuilder: sector_length exceeds STRAIGHT_LENGTH"
	)

	local height = p.height_or_depth
	local folder = getSectorFolder(state.sector_id)
	local color = BrickColor.new("Medium stone grey")
	local startOffset = math.max(0, (Constants.STRAIGHT_LENGTH - p.sector_length) * 0.5)

	makeFlatRunout("EntryFlat", entryFrame, 0, startOffset, color, folder)

	local points = {}
	for index = 0, CURVE_SEGMENTS do
		local t = index / CURVE_SEGMENTS
		local y = height * 0.5 * (1 - math.cos(2 * math.pi * t))
		table.insert(points, Vector3.new(0, y, startOffset + p.sector_length * t))
	end

	local prefix = if height >= 0 then "Crest" else "Dip"
	for index = 1, #points - 1 do
		makeSegment(
			string.format("%s_%02d", prefix, index),
			points[index],
			points[index + 1],
			entryFrame,
			color,
			folder
		)
	end

	local exitFlatLength = Constants.STRAIGHT_LENGTH - p.sector_length - startOffset
	makeFlatRunout("ExitFlat", entryFrame, startOffset + p.sector_length, exitFlatLength, color, folder)
end

return CrestDipBuilder
