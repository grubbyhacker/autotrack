-- ChicaneBuilder.luau
-- Builds Chicane as linked slow corners forming an overall S shape.
-- prd_plan.md §4.2, Phase 4

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ChicanePath = require(script.Parent.ChicanePath)
local TrackVisuals = require(script.Parent.Parent.Track.TrackVisuals)

type SectorState = Types.SectorState

local ChicaneBuilder = {}

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
	TrackVisuals.addCurbs(part)
	TrackVisuals.addAlternatingStripes(part, Constants.CAR_WIDTH * 0.2)
	return part
end

function ChicaneBuilder.build(state: SectorState, entryFrame: CFrame, exitFrame: CFrame)
	local p = state.params
	assert(p.amplitude,          "ChicaneBuilder: missing amplitude")
	assert(p.transition_length,  "ChicaneBuilder: missing transition_length")
	assert(p.corridor_width,     "ChicaneBuilder: missing corridor_width")
	assert(p.amplitude > 0,      "ChicaneBuilder: amplitude must be positive")
	assert(p.transition_length > 0, "ChicaneBuilder: transition_length must be positive")
	assert(p.corridor_width > 0, "ChicaneBuilder: corridor_width must be positive")

	local totalLength = ChicanePath.ENTRY_STRAIGHT + ChicanePath.EXIT_STRAIGHT + 3 * p.transition_length
	assert(
		totalLength <= Constants.STRAIGHT_LENGTH,
		"ChicaneBuilder: geometry exceeds STRAIGHT_LENGTH (" .. totalLength .. ")"
	)

	local amplitude = p.amplitude
	local transitionLength = p.transition_length
	local width = math.min(p.corridor_width, Constants.TRACK_WIDTH)
	local folder = getSectorFolder(state.sector_id)
	local color = BrickColor.new("Bright blue")
	local totalLength = ChicanePath.ENTRY_STRAIGHT + ChicanePath.EXIT_STRAIGHT + 3 * transitionLength
	local startOffset = math.max(0, (Constants.STRAIGHT_LENGTH - totalLength) * 0.5)

	if startOffset > 0 then
		local worldStart = worldPoint(entryFrame, Vector3.new(0, 0, 0))
		local worldEnd = worldPoint(entryFrame, Vector3.new(0, 0, startOffset))
		local delta = worldEnd - worldStart
		local center = worldStart:Lerp(worldEnd, 0.5)
		local cf = CFrame.lookAt(center, center + delta.Unit)
		makePart("ChicEntryFlat", Vector3.new(width, Constants.TRACK_THICKNESS, startOffset), cf, color, folder)
	end

	local points = ChicanePath.buildLocalCenterlinePoints(amplitude, transitionLength)
	local featureStartIndex = if startOffset > 0 then 2 else 1
	local featurePointCount = #points - featureStartIndex

	local names = { "ChicEntry" }
	for turnIndex = 1, 3 do
		for segmentIndex = 1, ChicanePath.TURN_SEGMENTS do
			table.insert(names, string.format("ChicTurn%d_%02d", turnIndex, segmentIndex))
		end
	end
	table.insert(names, "ChicExit")

	assert(featurePointCount == #names + 1, "ChicaneBuilder: point/name count mismatch")
	for index, name in ipairs(names) do
		local startPoint = points[featureStartIndex + index - 1]
		local endPoint = points[featureStartIndex + index]
		local worldStart = worldPoint(entryFrame, startPoint)
		local worldEnd = worldPoint(entryFrame, endPoint)
		local delta = worldEnd - worldStart
		local length = delta.Magnitude
		assert(length > 0, "ChicaneBuilder.build: zero-length segment")
		local center = worldStart:Lerp(worldEnd, 0.5)
		local cf = CFrame.lookAt(center, center + delta.Unit)
		makePart(name, Vector3.new(width, Constants.TRACK_THICKNESS, length), cf, color, folder)
	end

	local exitFlatLength = Constants.STRAIGHT_LENGTH - totalLength - startOffset
	if exitFlatLength > 0 then
		local startPoint = Vector3.new(0, 0, startOffset + totalLength)
		local endPoint = Vector3.new(0, 0, Constants.STRAIGHT_LENGTH)
		local worldStart = worldPoint(entryFrame, startPoint)
		local worldEnd = worldPoint(entryFrame, endPoint)
		local delta = worldEnd - worldStart
		local center = worldStart:Lerp(worldEnd, 0.5)
		local cf = CFrame.lookAt(center, center + delta.Unit)
		makePart("ChicExitFlat", Vector3.new(width, Constants.TRACK_THICKNESS, exitFlatLength), cf, color, folder)
	end
end

return ChicaneBuilder
