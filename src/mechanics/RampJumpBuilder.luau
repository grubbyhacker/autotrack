--!strict
-- RampJumpBuilder.luau
-- Builds RampJump geometry from a SectorState.
-- prd_plan.md §4.1, Phase 4 / Phase 15

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Types"))
local Constants = require(ReplicatedStorage:WaitForChild("AutoTrackCommon"):WaitForChild("Constants"))
local TrackVisuals = require(script.Parent.Parent.Track.TrackVisuals)
local RampJumpPath = require(script.Parent.RampJumpPath)

type SectorState = Types.SectorState

local RampJumpBuilder = {}

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
	assert(length > 0, "RampJumpBuilder.makeSegment: zero-length segment")
	local worldStart = worldPoint(entryFrame, startPoint)
	local worldEnd = worldPoint(entryFrame, endPoint)
	local center = worldStart:Lerp(worldEnd, 0.5)
	local cf = CFrame.lookAt(center, center + (worldEnd - worldStart).Unit)
	return makePart(name, Vector3.new(Constants.TRACK_WIDTH, Constants.TRACK_THICKNESS, length), cf, color, parent)
end

function RampJumpBuilder.build(state: SectorState, entryFrame: CFrame, _exitFrame: CFrame)
	local p = state.params
	assert(p.ramp_angle, "RampJumpBuilder: missing ramp_angle")
	assert(p.ramp_length, "RampJumpBuilder: missing ramp_length")
	assert(p.gap_length, "RampJumpBuilder: missing gap_length")
	assert(p.landing_length, "RampJumpBuilder: missing landing_length")

	local totalHorizontal = p.ramp_length + p.gap_length + p.landing_length
	assert(
		totalHorizontal <= Constants.STRAIGHT_LENGTH,
		"RampJumpBuilder: geometry exceeds STRAIGHT_LENGTH (" .. totalHorizontal .. ")"
	)

	local folder = getSectorFolder(state.sector_id)
	local profile = RampJumpPath.buildProfile(p.ramp_angle, p.ramp_length, p.gap_length, p.landing_length)
	local lastSlopedSegment: Part? = nil

	for index = 2, #profile.rampPoints do
		local startPoint = profile.rampPoints[index - 1]
		local endPoint = profile.rampPoints[index]
		local kind = "Ramp"
		local color = BrickColor.new("Bright orange")
		if math.abs(startPoint.Y) < 1e-4 and math.abs(endPoint.Y) < 1e-4 then
			kind = "EntryFlat"
			color = BrickColor.new("Medium stone grey")
		elseif endPoint.Z <= profile.blendEndZ + 1e-4 then
			kind = "RampBlend"
		end

		local part =
			makeSegment(string.format("%s_%02d", kind, index - 1), startPoint, endPoint, entryFrame, color, folder)
		if kind ~= "EntryFlat" then
			lastSlopedSegment = part
			TrackVisuals.addRampSupports(part, math.max(startPoint.Y, endPoint.Y))
		end
	end

	for index = 2, #profile.landingPoints do
		local startPoint = profile.landingPoints[index - 1]
		local endPoint = profile.landingPoints[index]
		local kind = if endPoint.Z <= profile.landingEndZ + 1e-4 then "Landing" else "ExitFlat"
		local color = if kind == "Landing"
			then BrickColor.new("Dark stone grey")
			else BrickColor.new("Medium stone grey")
		local part =
			makeSegment(string.format("%s_%02d", kind, index - 1), startPoint, endPoint, entryFrame, color, folder)
		if kind == "Landing" then
			TrackVisuals.addCurbs(part)
		end
	end

	if lastSlopedSegment ~= nil then
		TrackVisuals.addRampArrow(lastSlopedSegment)
	end
end

return RampJumpBuilder
