--!strict

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
local CrestDipPath = require(script.Parent.CrestDipPath)

type SectorState = Types.SectorState

type CrestDipBuilderModule = {
	build: (state: SectorState, entryFrame: CFrame, exitFrame: CFrame) -> (),
}

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
	return makePart(name, Vector3.new(Constants.TRACK_WIDTH, Constants.TRACK_THICKNESS, length), cf, color, parent)
end

local function build(state: SectorState, entryFrame: CFrame, _exitFrame: CFrame): ()
	local p = state.params
	local height = assert(p.height_or_depth, "CrestDipBuilder: missing height_or_depth")
	assert(p.radius, "CrestDipBuilder: missing radius")
	local sectorLength = assert(p.sector_length, "CrestDipBuilder: missing sector_length")
	assert(sectorLength <= Constants.STRAIGHT_LENGTH, "CrestDipBuilder: sector_length exceeds STRAIGHT_LENGTH")

	local folder = getSectorFolder(state.sector_id)
	local color = BrickColor.new("Medium stone grey")
	local points = CrestDipPath.buildLocalCenterlinePoints(height, sectorLength)
	local prefix = if height >= 0 then "Crest" else "Dip"
	for index = 1, #points - 1 do
		local startPoint = points[index]
		local endPoint = points[index + 1]
		local isFlat = math.abs(startPoint.Y) < 1e-4 and math.abs(endPoint.Y) < 1e-4
		local segmentName = string.format("%s_%02d", prefix, index)
		if isFlat and index == 1 then
			segmentName = "EntryFlat"
		elseif isFlat and index == #points - 1 then
			segmentName = "ExitFlat"
		end
		makeSegment(segmentName, startPoint, endPoint, entryFrame, color, folder)
	end
end

local CrestDipBuilder: CrestDipBuilderModule = {
	build = build,
}

return CrestDipBuilder
