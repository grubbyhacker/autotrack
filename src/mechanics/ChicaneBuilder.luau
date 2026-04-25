--!strict

-- ChicaneBuilder.luau
-- Builds Chicane as a smooth sine-like wave across the straight.
-- prd_plan.md §4.2, Phase 4

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local ChicanePath = require(script.Parent.ChicanePath)
local TrackVisuals = require(script.Parent.Parent.Track.TrackVisuals)

type SectorState = Types.SectorState

type ChicaneBuilderModule = {
	build: (state: SectorState, entryFrame: CFrame, exitFrame: CFrame) -> (),
}

local CHICANE_VISUAL_SURFACE_OVERLAP = 0.18

local function worldPoint(entryFrame: CFrame, point: Vector3): Vector3
	return entryFrame.Position
		+ entryFrame.RightVector * point.X
		+ entryFrame.UpVector * point.Y
		+ entryFrame.LookVector * point.Z
end

local function getSectorFolder(sector_id: number): Folder
	return TrackVisuals.getCollisionFolder(sector_id)
end

local function makePart(name: string, size: Vector3, cf: CFrame, sectorId: number, parent: Instance): Part
	return TrackVisuals.makeCollisionPart(parent, name, size, cf, sectorId, "Straight")
end

local function build(state: SectorState, entryFrame: CFrame, _exitFrame: CFrame): ()
	local p = state.params
	local amplitude = assert(p.amplitude, "ChicaneBuilder: missing amplitude")
	local transitionLength = assert(p.transition_length, "ChicaneBuilder: missing transition_length")
	local corridorWidth = assert(p.corridor_width, "ChicaneBuilder: missing corridor_width")
	assert(amplitude > 0, "ChicaneBuilder: amplitude must be positive")
	assert(transitionLength > 0, "ChicaneBuilder: transition_length must be positive")
	assert(corridorWidth > 0, "ChicaneBuilder: corridor_width must be positive")

	local totalLength = ChicanePath.totalLength(transitionLength)
	assert(
		totalLength <= Constants.STRAIGHT_LENGTH,
		"ChicaneBuilder: geometry exceeds STRAIGHT_LENGTH (" .. totalLength .. ")"
	)

	local width = math.min(corridorWidth, Constants.TRACK_WIDTH)
	local visualWidth = Constants.TRACK_WIDTH
	local folder = getSectorFolder(state.sector_id)
	local startOffset = math.max(0, (Constants.STRAIGHT_LENGTH - totalLength) * 0.5)

	if startOffset > 0 then
		local worldStart = worldPoint(entryFrame, Vector3.new(0, 0, 0))
		local worldEnd = worldPoint(entryFrame, Vector3.new(0, 0, startOffset))
		local delta = worldEnd - worldStart
		local center = worldStart:Lerp(worldEnd, 0.5)
		local cf = CFrame.lookAt(center, center + delta.Unit)
		makePart(
			"ChicEntryFlat",
			Vector3.new(width, Constants.TRACK_THICKNESS, startOffset),
			cf,
			state.sector_id,
			folder
		)
	end

	local points = ChicanePath.buildLocalCenterlinePoints(amplitude, transitionLength)
	local visualPoints = ChicanePath.buildLocalVisualCenterlinePoints(amplitude, transitionLength)
	local featureStartIndex = if startOffset > 0 then 2 else 1
	local featureSegmentCount = (#points - featureStartIndex)

	for index = 1, featureSegmentCount do
		local startPoint = points[featureStartIndex + index - 1]
		local endPoint = points[featureStartIndex + index]
		local worldStart = worldPoint(entryFrame, startPoint)
		local worldEnd = worldPoint(entryFrame, endPoint)
		local delta = worldEnd - worldStart
		local length = delta.Magnitude
		assert(length > 0, "ChicaneBuilder.build: zero-length segment")
		local center = worldStart:Lerp(worldEnd, 0.5)
		local cf = CFrame.lookAt(center, center + delta.Unit)
		makePart(
			string.format("ChicSeg_%02d", index),
			Vector3.new(width, Constants.TRACK_THICKNESS, length),
			cf,
			state.sector_id,
			folder
		)
	end

	local exitFlatLength = Constants.STRAIGHT_LENGTH - (startOffset + totalLength)
	if exitFlatLength > 0 then
		local startPoint = Vector3.new(0, 0, startOffset + totalLength)
		local endPoint = Vector3.new(0, 0, Constants.STRAIGHT_LENGTH)
		local worldStart = worldPoint(entryFrame, startPoint)
		local worldEnd = worldPoint(entryFrame, endPoint)
		local delta = worldEnd - worldStart
		local center = worldStart:Lerp(worldEnd, 0.5)
		local cf = CFrame.lookAt(center, center + delta.Unit)
		makePart(
			"ChicExitFlat",
			Vector3.new(width, Constants.TRACK_THICKNESS, exitFlatLength),
			cf,
			state.sector_id,
			folder
		)
	end

	local visualFolder = TrackVisuals.getVisualFolder(state.sector_id)
	local worldVisualPoints: { Vector3 } = table.create(#visualPoints)
	for index, point in ipairs(visualPoints) do
		worldVisualPoints[index] = worldPoint(entryFrame, point)
	end
	TrackVisuals.renderPathSurface(
		visualFolder,
		worldVisualPoints,
		visualWidth,
		false,
		false,
		CHICANE_VISUAL_SURFACE_OVERLAP,
		nil,
		nil,
		nil,
		false,
		true
	)
end

local ChicaneBuilder: ChicaneBuilderModule = {
	build = build,
}

return ChicaneBuilder
